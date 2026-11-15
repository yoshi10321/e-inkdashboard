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


# --- 気象庁の予報 ---------------------------------------------------
#
# なぜ Open-Meteo だけにしないか。
#
# Open-Meteo の既定は best_match（モデル自動選択）で、気象庁モデルでは
# ない。2026-11-15 に実測したところ、同じ座標・同じ日でこれだけ違った。
#
#   日付        11/19  11/20
#   best_match    55     51    霧雨
#   jma_seamless   2      0    晴れ〜薄曇り
#
# Yahoo!天気・NHK・tenki.jp はいずれも気象庁の発表予報が元なので、
# best_match のままでは食い違って当たり前だった。
#
# では models=jma_seamless にすれば済むかというと、済まない。
# **気象庁モデルは降水確率を返さない**（実測で8日ぶん全部 None）。
# しかも jma_seamless は数値予報モデルの出力であって、気象庁が発表する
# 「府県天気予報」そのものではない。手元のアプリと一致させたいなら、
# 発表予報そのものを取るしかない。
#
# そこで天気マークと降水確率だけ気象庁から取り、気温・日の出入・
# 現在の気象は Open-Meteo（座標ピンポイント）のまま使う。
# 気温は best_match と jma_seamless で最大 0.9℃ しか違わなかったので、
# 粗い代表地点の値に置き換える利点がない（週間の気温は熊谷のぶんしか
# 公開されておらず、草加とは内陸ぶんずれる）。
#
# エンドポイントは気象庁の bosai JSON。公式に仕様公開されたものではない
# ので、**形が変わりうる前提**で書く。失敗しても Open-Meteo の値が
# 残るだけで画面は出る。

JMA_URL = "https://www.jma.go.jp/bosai/forecast/data/forecast/{office}.json"

# 気象庁の天気コード → WMO コード。
#
# index.html は WMO コードでアイコンを分岐しているので変換が要る。
# 気象庁の表（ページ内の R.TELOPS）は 5 要素
#   [昼svg, 夜svg, 代表コード, 和名, 英名]
# で、3 番目の代表コード（100晴 / 200曇 / 300雨 / 400雪）が
# **気象庁自身がアイコンに使っている分類**。これを優先する。
# そのため和名に「雷雨」や「雪」が混ざっていても、代表が 100 なら
# 晴として扱う（123 晴山沿い雷雨、124 晴山沿い雪）。
#
# この表は実機ではなく気象庁のページから抜いて機械生成した。
# 手で書き写すと必ず取りこぼす。全 118 件。
JMA_TO_WMO = {
    100: 0, 101: 2, 102: 61, 103: 61, 104: 71, 105: 71,
    106: 61, 107: 61, 108: 95, 110: 2, 111: 2, 112: 61,
    113: 61, 114: 61, 115: 71, 116: 71, 117: 71, 118: 61,
    119: 95, 120: 61, 121: 61, 122: 61, 123: 1, 124: 1,
    125: 95, 126: 61, 127: 61, 128: 61, 130: 1, 131: 1,
    132: 2, 140: 95, 160: 71, 170: 71, 181: 71, 200: 3,
    201: 2, 202: 61, 203: 61, 204: 71, 205: 71, 206: 61,
    207: 61, 208: 95, 209: 45, 210: 2, 211: 2, 212: 61,
    213: 61, 214: 61, 215: 71, 216: 71, 217: 71, 218: 61,
    219: 95, 220: 61, 221: 61, 222: 61, 223: 2, 224: 61,
    225: 61, 226: 61, 228: 71, 229: 71, 230: 71, 231: 3,
    240: 95, 250: 71, 260: 71, 270: 71, 281: 71, 300: 61,
    301: 61, 302: 61, 303: 71, 304: 61, 306: 61, 308: 61,
    309: 71, 311: 61, 313: 61, 314: 71, 315: 71, 316: 61,
    317: 61, 320: 61, 321: 61, 322: 71, 323: 61, 324: 61,
    325: 61, 326: 71, 327: 71, 328: 61, 329: 61, 340: 71,
    350: 95, 361: 71, 371: 71, 400: 71, 401: 71, 402: 71,
    403: 71, 405: 71, 406: 71, 407: 71, 409: 71, 411: 71,
    413: 71, 414: 71, 420: 71, 421: 71, 422: 71, 423: 71,
    425: 71, 426: 71, 427: 71, 450: 71,
}


def _jma_wmo(code):
    """未知のコードが来ても落とさない。百の位で大まかに振る。"""
    w = JMA_TO_WMO.get(int(code))
    if w is not None:
        return w
    head = int(code) // 100
    return {1: 1, 2: 3, 3: 61, 4: 71}.get(head, 3)


def _jma_pick(series_list, area_code, key):
    """timeSeries の中から、指定区域の指定項目を {日付: 値} で返す。

    **位置（index）で取らないこと。** 気象庁の発表は 05/11/17 時の
    3 回あり、発表時刻によって timeDefines の起点が変わる。
    位置で取ると発表時刻をまたいだ瞬間に 1 日ずれる。日付で引く。
    """
    out = {}
    for ts in series_list:
        times = ts.get("timeDefines") or []
        for area in ts.get("areas") or []:
            if (area.get("area") or {}).get("code") != area_code:
                continue
            vals = area.get(key)
            if not vals:
                continue
            for t, v in zip(times, vals):
                if v in (None, ""):
                    continue
                day = t[:10]
                # 同じ日に複数あるとき（降水確率は 6 時間ごと）は最大を採る。
                # 「今日の降水確率」として各社が出しているのもこの形。
                prev = out.get(day)
                try:
                    v = int(v)
                except (TypeError, ValueError):
                    continue
                out[day] = v if prev is None else max(prev, v)
    return out


def fetch_jma(office, area):
    """気象庁の発表予報から {日付: 天気コード} と {日付: 降水確率} を作る。"""
    d = json.loads(get(JMA_URL.format(office=office)))
    if not isinstance(d, list) or not d:
        raise RuntimeError("気象庁の応答が配列でない")

    short = (d[0].get("timeSeries") or []) if len(d) > 0 else []
    week = (d[1].get("timeSeries") or []) if len(d) > 1 else []

    # 天気コードと降水確率。
    # 短期（3日ぶん）は一次細分区域＝草加なら南部。
    # 週間（7日ぶん）は府県単位でしか出ないので office を使う。
    # 日付が重なるところは短期を優先する（区域が細かく、発表も新しい）。
    codes = dict(_jma_pick(week, office, "weatherCodes"))
    codes.update(_jma_pick(short, area, "weatherCodes"))

    pops = dict(_jma_pick(week, office, "pops"))
    pops.update(_jma_pick(short, area, "pops"))

    if not codes:
        raise RuntimeError(
            f"天気コードが1日ぶんも取れない（区域 {area}/{office} が応答に無い）")

    return {
        "weather_codes": {k: _jma_wmo(v) for k, v in codes.items()},
        "pops": pops,
        "report": (d[0].get("reportDatetime") or "")[:16],
        "office": d[0].get("publishingOffice") or "",
    }


def merge_jma(out):
    """Open-Meteo の weather ブロックに気象庁の値を上書きする。

    上書きするのは天気コードと降水確率だけ。気温・日の出入・現在の気象は
    Open-Meteo のまま。返り値は画面やログに出す短い説明。

    weather ブロックの形は変えない。index.html も、天気が取れなかった
    ときに直前ぶんで埋める仕組みも、そのまま動く。
    """
    w = out.get("weather")
    if not w or "daily" not in w:
        return None

    office = os.environ.get("DASH_JMA_OFFICE", "").strip()
    area = os.environ.get("DASH_JMA_AREA", "").strip() or office
    if not office:
        raise RuntimeError(
            "DASH_JMA_OFFICE が未設定。気象庁ではなく Open-Meteo の"
            " best_match の予報が出る（手元のアプリと食い違う）")

    jma = fetch_jma(office, area)
    days = w["daily"].get("time") or []
    codes, pops = jma["weather_codes"], jma["pops"]

    hit_c = hit_p = 0
    for i, day in enumerate(days):
        if day in codes:
            w["daily"]["weather_code"][i] = codes[day]
            hit_c += 1
        if day in pops and "precipitation_probability_max" in w["daily"]:
            w["daily"]["precipitation_probability_max"][i] = pops[day]
            hit_p += 1

    # 今日の天気は current にも出ている。画面の大きいアイコンがこれ。
    today = out.get("for_date")
    if today in codes and isinstance(w.get("current"), dict):
        w["current"]["weather_code"] = codes[today]

    out["weather_source"] = "気象庁"
    out["weather_report"] = jma["report"]
    return (f"気象庁 {jma['office']} {jma['report']} /"
            f" 天気{hit_c}日・降水確率{hit_p}日を上書き")


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
    # 直前ぶんには気象庁の上書きが入っている。出どころも一緒に引き継ぐ。
    # ここを忘れると、気象庁の予報を出しているのに
    # 「Open-Meteo」と記録されて、後から原因を追えなくなる。
    for k in ("weather_source", "weather_report"):
        if prev.get(k):
            out[k] = prev[k]
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

    # 天気マークと降水確率を気象庁の発表予報で上書きする。
    #
    # ここが失敗しても Open-Meteo の値が残るだけなので、画面は出る。
    # ただし「手元のアプリと食い違う状態に戻った」ことは残す。黙らない。
    out["weather_source"] = "Open-Meteo"
    if out.get("weather") is not None:
        print("気象庁の発表予報で上書き中…")
        try:
            note = merge_jma(out)
            print(f"  OK {note}")
        except Exception as e:          # noqa: BLE001
            print(f"  失敗: {e}", file=sys.stderr)
            print(f"::warning::気象庁から取れなかったので Open-Meteo の"
                  f"予報が出る: {str(e)[:200]}")
            errors["jma"] = str(e)[:600]

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
