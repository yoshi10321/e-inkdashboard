#!/usr/bin/env python3
"""
ダッシュボードに表示するデータをまとめて取得し、data.json として書き出す。

ブラウザから直接 API を叩くと CORS や相手側の制限で失敗することがあるため、
GitHub Actions の中でサーバーとして取得してしまう。
index.html は data.json があればそれを使い、無ければ従来どおり直接 API を叩く。

どれか一つが失敗しても、残りは出力する。
"""

import gzip
import io
import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone

JST = timezone(timedelta(hours=9))

# 座標は公開リポジトリに置かず、GitHub の Secrets から環境変数で渡す。
# 設定が無ければ黙って別の場所の天気を出すより、はっきり落とすほうがよい。
#
# ローカルで試すとき:  DASH_LAT=35.84 DASH_LON=139.80 python3 fetch_data.py
def _coord(name):
    v = os.environ.get(name, "").strip()
    if not v:
        raise SystemExit(
            f"環境変数 {name} が設定されていない。"
            " GitHub の Secrets（DASH_LAT / DASH_LON）を確認すること。"
        )
    return float(v)


LAT = _coord("DASH_LAT")
LON = _coord("DASH_LON")
TZ = "Asia/Tokyo"

# 何分先を「今日」とみなすか。
#
# 画像を作るのに 1〜8 分かかり、ばらつきが大きい。0 時を回ってから作り始めると
# 端末が取りに来るまでに間に合わないことがある。
# 日付が変わる少し前に「翌日ぶん」として作っておけば、0 時には出来上がっている。
#
# 23:50 に起動した場合: 23:50 + 20分 = 00:10 → 翌日ぶんとして作る
# 23:30 に起動した場合: 23:30 + 20分 = 23:50 → 当日ぶんのまま
LOOKAHEAD_MIN = 20

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"


def get_bytes(url, tries=3, timeout=20, headers=None):
    """単純な GET（バイト列のまま返す）。失敗したら少し待って再試行する。"""
    h = {
        "User-Agent": UA,
        "Accept": "*/*",
        # gzip で返されると扱いが面倒なので、できれば生で欲しいと伝える
        "Accept-Encoding": "identity",
    }
    if headers:
        h.update(headers)

    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                # それでも gzip で返ってくる相手がいる
                if raw[:2] == b"\x1f\x8b":
                    raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read()
                return raw
        except Exception as e:          # noqa: BLE001 - 失敗理由は問わず再試行する
            last = e
            print(f"  試行 {i + 1}/{tries} 失敗: {e}", file=sys.stderr)
            if i < tries - 1:
                import time
                time.sleep(2 * (i + 1))
    raise RuntimeError(f"取得できませんでした: {url} ({last})")


def get(url, tries=3, timeout=20, headers=None):
    """GET して UTF-8 の文字列として返す。"""
    return get_bytes(url, tries, timeout, headers).decode("utf-8", "replace")


def parse_date_value_csv(text, what):
    """「日付,値」の2列以上の CSV から、値のある行だけを拾う。
    FRED は欠損日を "." で表すので、それは飛ばす。"""
    lines = [l for l in text.replace("\r", "").split("\n") if l.strip()]
    if len(lines) < 2:
        raise RuntimeError(f"{what}: 行が足りない（先頭: {text[:120]!r}）")

    values, last_date = [], ""
    for line in lines[1:]:
        cols = line.split(",")
        if len(cols) < 2:
            continue
        try:
            values.append(float(cols[1]))
            last_date = cols[0]
        except ValueError:
            continue        # "." など
    if not values:
        raise RuntimeError(f"{what}: 数値を取り出せなかった（先頭: {text[:120]!r}）")
    return values, last_date


# --- 天気 -----------------------------------------------------------

def fetch_weather():
    url = (
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={LAT}&longitude={LON}"
        "&current=temperature_2m,weather_code,relative_humidity_2m,"
        "wind_speed_10m,apparent_temperature"
        "&hourly=temperature_2m,weather_code,precipitation_probability"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,"
        "precipitation_probability_max,sunrise,sunset"
        # 明日から 7 日ぶん並べる。先読みで 1 日ずれる場合に備えて 9 日ぶん取る
        f"&timezone={TZ.replace('/', '%2F')}&forecast_days=9"
    )
    d = json.loads(get(url))
    if "current" not in d or "daily" not in d:
        raise RuntimeError("天気データの形式が想定と違う")
    return strip_location(d)


def strip_location(d):
    """応答に混ざっている位置情報を落とす。

    Open-Meteo は問い合わせたグリッド点の座標と標高を返してくる。
    data.json は誰でも取得できるので、公開物に入る前に必ずここを通す。
    前回ぶんを使い回すときも、念のためもう一度通す。
    """
    for k in ("latitude", "longitude", "elevation",
              "generationtime_ms", "utc_offset_seconds"):
        d.pop(k, None)
    return d


# --- ドル円 ---------------------------------------------------------

def fetch_fx():
    start = (datetime.now(JST) - timedelta(days=30)).strftime("%Y-%m-%d")
    url = f"https://api.frankfurter.dev/v1/{start}..?base=USD&symbols=JPY"
    d = json.loads(get(url))
    rates = d.get("rates") or {}
    if not rates:
        raise RuntimeError("為替データが空")
    dates = sorted(rates.keys())
    series = [rates[k]["JPY"] for k in dates]
    return {
        "series": series,
        "last": series[-1],
        "prev": series[-2] if len(series) > 1 else None,
        "label": "ECB " + dates[-1],
    }


# --- 日経平均 -------------------------------------------------------
# ブラウザからは CORS で弾かれる。サーバーからでも、Stooq や Yahoo は
# データセンターの IP からの取得を断ることがある。
# そのため取得元を複数用意して、取れたところを使う。

def _nikkei_from_nikkei_inc():
    """日本経済新聞社が公開している日経平均の日次 CSV。
    文字コードは Shift-JIS で、末尾に注記の行が入る。"""
    url = ("https://indexes.nikkei.co.jp/nkave/historical/"
           "nikkei_stock_average_daily_jp.csv")
    text = get_bytes(url, timeout=30).decode("cp932", "replace")
    lines = [l for l in text.replace("\r", "").split("\n") if l.strip()]
    closes, last_date = [], ""
    for line in lines[1:]:
        cols = [c.strip().strip('"') for c in line.split(",")]
        if len(cols) < 2:
            continue
        try:
            closes.append(float(cols[1].replace(",", "")))
            last_date = cols[0].replace("/", "-")
        except ValueError:
            continue        # 末尾の注記行など
    if not closes:
        raise RuntimeError(f"日経社の CSV を読めなかった（先頭: {text[:120]!r}）")
    return closes[-60:], last_date


def _nikkei_from_fred_csv():
    """セントルイス連銀 (FRED) の NIKKEI225。API キー不要。
    グラフ用の CSV は生成に時間がかかるので待ち時間を長めに取る。"""
    to = datetime.now(JST)
    frm = to - timedelta(days=90)
    url = ("https://fred.stlouisfed.org/graph/fredgraph.csv?id=NIKKEI225"
           f"&cosd={frm.strftime('%Y-%m-%d')}&coed={to.strftime('%Y-%m-%d')}")
    closes, last_date = parse_date_value_csv(get(url, timeout=60), "FRED(csv)")
    return closes[-60:], last_date


def _nikkei_from_fred_txt():
    """FRED が置いている素のテキスト。全期間ぶんあるが静的ファイルなので速い。
        DATE                 VALUE
        1949-05-16           176.21
    という空白区切りで、欠損は "." 。"""
    text = get("https://fred.stlouisfed.org/data/NIKKEI225.txt", timeout=60)
    closes, last_date = [], ""
    for line in text.replace("\r", "").split("\n"):
        parts = line.split()
        if len(parts) != 2 or "-" not in parts[0]:
            continue        # 冒頭の説明文や見出し
        try:
            closes.append(float(parts[1]))
            last_date = parts[0]
        except ValueError:
            continue        # "."
    if not closes:
        raise RuntimeError(f"FRED のテキストを読めなかった（先頭: {text[:120]!r}）")
    return closes[-60:], last_date


def _nikkei_from_stooq():
    to = datetime.now(JST)
    frm = to - timedelta(days=90)
    url = (
        "https://stooq.com/q/d/l/?s=%5Enkx"
        f"&d1={frm.strftime('%Y%m%d')}&d2={to.strftime('%Y%m%d')}&i=d"
    )
    text = get(url)
    if "limit" in text.lower() and "," not in text:
        # 「Exceeded the daily hits limit」が本文で返ってくることがある
        raise RuntimeError(f"Stooq に断られた: {text.strip()[:80]}")
    lines = [l for l in text.replace("\r", "").split("\n") if l.strip()]
    if not lines or "Close" not in lines[0]:
        raise RuntimeError(f"Stooq の CSV が想定と違う（先頭: {text[:120]!r}）")
    header = lines[0].split(",")
    ci, di = header.index("Close"), header.index("Date")
    closes, last_date = [], ""
    for line in lines[1:]:
        cols = line.split(",")
        try:
            closes.append(float(cols[ci]))
            last_date = cols[di]
        except (ValueError, IndexError):
            continue
    if not closes:
        raise RuntimeError("Stooq から終値を取り出せなかった")
    return closes, last_date


def _nikkei_from_yahoo(host="query1"):
    url = (f"https://{host}.finance.yahoo.com/v8/finance/chart/"
           "%5EN225?range=3mo&interval=1d")
    d = json.loads(get(url, headers={"Accept": "application/json"}))
    chart = d.get("chart") or {}
    if chart.get("error"):
        raise RuntimeError(f"Yahoo がエラーを返した: {chart['error']}")
    r = (chart.get("result") or [None])[0]
    if not r:
        raise RuntimeError("Yahoo の応答に result が無い")
    raw = r["indicators"]["quote"][0]["close"]
    ts = r["timestamp"]
    closes, last_ts = [], None
    for v, t in zip(raw, ts):
        if v is not None:
            closes.append(float(v))
            last_ts = t
    if not closes:
        raise RuntimeError("Yahoo から終値を取り出せなかった")
    label = datetime.fromtimestamp(last_ts, JST).strftime("%Y-%m-%d")
    return closes, label


# 上から順に試す。
# Stooq と Yahoo はデータセンターの IP だと断られる（bot 判定・429）ので後ろに置く。
NIKKEI_SOURCES = (
    ("日経社CSV", _nikkei_from_nikkei_inc),
    ("FRED(txt)", _nikkei_from_fred_txt),
    ("FRED(csv)", _nikkei_from_fred_csv),
    ("Yahoo(query1)", lambda: _nikkei_from_yahoo("query1")),
    ("Yahoo(query2)", lambda: _nikkei_from_yahoo("query2")),
    ("Stooq", _nikkei_from_stooq),
)


def fetch_nikkei():
    errors = []
    for name, fn in NIKKEI_SOURCES:
        print(f"  {name} を試す")
        try:
            closes, label = fn()
        except Exception as e:          # noqa: BLE001
            print(f"    だめだった: {e}", file=sys.stderr)
            errors.append(f"{name}: {e}")
            continue
        print(f"  日経は {name} から取得できた（{len(closes)}件, 最終 {label}）")
        return {
            "series": closes,
            "last": closes[-1],
            "prev": closes[-2] if len(closes) > 1 else None,
            "label": "終値 " + label,
            "source": name,
        }
    raise RuntimeError(" / ".join(errors))


# --- 天気が取れなかったときの埋め合わせ -----------------------------
#
# 2026-10-10 10:01 のビルドで Open-Meteo が HTTP 503 を返し、3回の再試行も
# 全部落ちた。結果、天気の枠が丸ごと「取得できませんでした」になり、
# 次の更新まで 1 時間そのままになった。上流が数秒こけただけで画面が
# 使い物にならなくなるのは割に合わない。
#
# 天気は 1 時間でそう変わらないので、直前に公開したぶんを出すほうがよい。
# ただし「いつ時点のものか」は画面に出す。黙って古い値を見せない。

# 何分前のものまで使い回してよいか
STALE_MAX_MIN = 180

# ワークフローが直前の公開ぶんを落としてくるファイル。無ければ使い回さない。
PREV_PATH = os.environ.get("PREV_DATA", "prev_data.json")


def reuse_prev_weather(out):
    """直前に公開した data.json の天気で埋める。

    埋めたら、その旨を説明する文字列を返す。埋めなかったら None。
    """
    if not os.path.exists(PREV_PATH):
        print("  直前ぶんが無いので埋められない", file=sys.stderr)
        return None
    try:
        with open(PREV_PATH, encoding="utf-8") as f:
            prev = json.load(f)
    except Exception as e:                      # noqa: BLE001
        print(f"  直前ぶんを読めなかった: {e}", file=sys.stderr)
        return None

    w = prev.get("weather")
    if not w or "daily" not in w or "current" not in w:
        print("  直前ぶんにも天気が入っていない", file=sys.stderr)
        return None

    # 【要】日付の並びが合っているか。
    #
    # index.html は daily[day_offset] を「画面に出す日」として読む。
    # 23:50 のビルドは翌日ぶん（day_offset=1）、0時すぎは当日ぶん（0）で、
    # 同じ for_date でも配列の起点が違う。generated の新しさだけで判断すると
    # 日付をまたいだ瞬間に 1 日ずれた予報を出すことになる。
    # そこで配列そのものを引いて、狙った日付と一致するかを確かめる。
    days = (w.get("daily") or {}).get("time") or []
    off = out["day_offset"]
    if off >= len(days) or days[off] != out["for_date"]:
        got = days[off] if off < len(days) else "（範囲外）"
        print(f"  直前ぶんは日付が合わない（daily[{off}]={got} / "
              f"欲しいのは {out['for_date']}）", file=sys.stderr)
        return None

    # 現在の気温などは古くなる。どこまで許すかを決めておく。
    as_of = prev.get("generated")
    try:
        age = (datetime.now(JST)
               - datetime.strptime(as_of, "%Y-%m-%dT%H:%M").replace(tzinfo=JST))
        age_min = int(age.total_seconds() // 60)
    except Exception:                           # noqa: BLE001
        print(f"  直前ぶんの generated を読めない（{as_of}）", file=sys.stderr)
        return None
    if age_min < 0 or age_min > STALE_MAX_MIN:
        print(f"  直前ぶんが古すぎる（{age_min}分前）", file=sys.stderr)
        return None

    # 公開物に座標を混ぜない。前回ぶんも通す。
    out["weather"] = strip_location(w)
    out["weather_as_of"] = as_of
    print(f"  天気は直前ぶん（{as_of} / {age_min}分前）で埋めた")
    return f"直前ぶん({as_of})で代用"


# --- まとめ ---------------------------------------------------------

def compute_dates(now):
    """その時刻のビルドが「何日ぶんとして」作られるかを決める。

    0 時ちょうどに作り始めるとビルドが間に合わず前日の画像が出るので、
    23:50 に翌日ぶんを先に作っている。LOOKAHEAD_MIN 分先を「今日」とみなす。

    ここは 0 時前後でしか効かないうえ、間違えても気づきにくい
    （画面に日付が 1 日ずれて出るだけ）。テストできるように切り出してある。
    """
    target = now + timedelta(minutes=LOOKAHEAD_MIN)
    return {
        "generated": now.strftime("%Y-%m-%dT%H:%M"),
        # 画面に出す日付。端末はこれを見て「本日ぶんか」を判断する
        "for_date": target.strftime("%Y-%m-%d"),
        # 天気データを何日ずらして読むか（0 なら当日、1 なら翌日）
        "day_offset": (target.date() - now.date()).days,
    }


def main():
    now = datetime.now(JST)
    out = compute_dates(now)
    day_offset = out["day_offset"]
    if day_offset:
        print(f"翌日ぶん（{out['for_date']}）として作る")
    errors = {}
    failed = []

    for key, fn, label in (
        ("weather", fetch_weather, "天気"),
        ("fx", fetch_fx, "ドル円"),
        ("nikkei", fetch_nikkei, "日経平均"),
    ):
        print(f"{label} を取得中…")
        try:
            out[key] = fn()
            print(f"  OK")
        except Exception as e:          # noqa: BLE001
            print(f"  失敗: {e}", file=sys.stderr)
            out[key] = None
            # Actions のログは後から読みにくいので、失敗理由も公開物に残す
            errors[key] = str(e)[:600]
            failed.append(label)

    # 天気が取れなかったときは、直前に公開したぶんで埋める。
    if out.get("weather") is None:
        note = reuse_prev_weather(out)
        if note:
            errors["weather"] = f"{note} / {errors.get('weather', '')}"[:600]
            if "天気" in failed:
                failed.remove("天気")

    if errors:
        out["errors"] = errors

    with open("data.json", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    print(f"\ndata.json を書き出した（{len(json.dumps(out))} bytes）")
    if failed:
        print(f"取得できなかったもの: {', '.join(failed)}", file=sys.stderr)
    # 一部が失敗してもワークフローは止めない（前回の値や代替表示で出す）
    return 0


if __name__ == "__main__":
    sys.exit(main())
