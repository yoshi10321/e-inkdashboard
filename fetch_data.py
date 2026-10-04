#!/usr/bin/env python3
"""
ダッシュボードに表示するデータをまとめて取得し、data.json として書き出す。

ブラウザから直接 API を叩くと CORS や相手側の制限で失敗することがあるため、
GitHub Actions の中でサーバーとして取得してしまう。
index.html は data.json があればそれを使い、無ければ従来どおり直接 API を叩く。

どれか一つが失敗しても、残りは出力する。
"""

import json
import sys
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone

JST = timezone(timedelta(hours=9))

LAT = 35.84          # 獨協大学前駅（小数2桁に丸め）
LON = 139.80
TZ = "Asia/Tokyo"

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"


def get(url, tries=3, timeout=20):
    """単純な GET。失敗したら少し待って再試行する。"""
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:          # noqa: BLE001 - 失敗理由は問わず再試行する
            last = e
            print(f"  試行 {i + 1}/{tries} 失敗: {e}", file=sys.stderr)
            if i < tries - 1:
                import time
                time.sleep(2 * (i + 1))
    raise RuntimeError(f"取得できませんでした: {url} ({last})")


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
        f"&timezone={TZ.replace('/', '%2F')}&forecast_days=7"
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
# ブラウザからは CORS で弾かれるが、サーバーからなら普通に取れる。

def _nikkei_from_stooq():
    to = datetime.now(JST)
    frm = to - timedelta(days=60)
    url = (
        "https://stooq.com/q/d/l/?s=%5Enkx"
        f"&d1={frm.strftime('%Y%m%d')}&d2={to.strftime('%Y%m%d')}&i=d"
    )
    text = get(url)
    lines = [l for l in text.replace("\r", "").split("\n") if l.strip()]
    if not lines or "Date" not in lines[0]:
        raise RuntimeError("Stooq の CSV が想定と違う")
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


def _nikkei_from_yahoo():
    url = ("https://query1.finance.yahoo.com/v8/finance/chart/"
           "%5EN225?range=2mo&interval=1d")
    d = json.loads(get(url))
    r = d["chart"]["result"][0]
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


def fetch_nikkei():
    errors = []
    for name, fn in (("Stooq", _nikkei_from_stooq), ("Yahoo", _nikkei_from_yahoo)):
        try:
            closes, label = fn()
            print(f"  日経は {name} から取得できた")
            return {
                "series": closes,
                "last": closes[-1],
                "prev": closes[-2] if len(closes) > 1 else None,
                "label": "終値 " + label,
            }
        except Exception as e:          # noqa: BLE001
            errors.append(f"{name}: {e}")
    raise RuntimeError(" / ".join(errors))


# --- まとめ ---------------------------------------------------------

def main():
    out = {"generated": datetime.now(JST).strftime("%Y-%m-%dT%H:%M")}
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
            failed.append(label)

    with open("data.json", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    print(f"\ndata.json を書き出した（{len(json.dumps(out))} bytes）")
    if failed:
        print(f"取得できなかったもの: {', '.join(failed)}", file=sys.stderr)
    # 一部が失敗してもワークフローは止めない（前回の値や代替表示で出す）
    return 0


if __name__ == "__main__":
    sys.exit(main())
