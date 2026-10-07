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
import sys
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone

JST = timezone(timedelta(hours=9))

LAT = 35.84          # 獨協大学前駅（小数2桁に丸め）
LON = 139.80
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


# --- まとめ ---------------------------------------------------------

def main():
    now = datetime.now(JST)
    target = now + timedelta(minutes=LOOKAHEAD_MIN)
    # 日付をまたいだ場合だけ 1 になる
    day_offset = (target.date() - now.date()).days

    out = {
        "generated": now.strftime("%Y-%m-%dT%H:%M"),
        # 画面に出す日付。端末はこれを見て「本日ぶんか」を判断する
        "for_date": target.strftime("%Y-%m-%d"),
        # 天気データを何日ずらして読むか（0 なら当日、1 なら翌日）
        "day_offset": day_offset,
    }
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
