#!/usr/bin/env python3
"""fetch_data.py のうち、間違えても気づきにくいところを固める。

ここで扱うのは「判断」の部分だけで、通信はしない。
外の API を叩くと、相手が落ちているだけでテストが赤くなって
意味が薄れる（実際 2026-10-10 に Open-Meteo が 503 を返した）。

    python3 tests/test_fetch_data.py
"""

import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# fetch_data は読み込み時に座標を要求してビルドを落とす。
# テストでは実際には使わないので、適当な値を入れておく。
os.environ.setdefault("DASH_LAT", "35.0")
os.environ.setdefault("DASH_LON", "139.0")

import fetch_data as fd  # noqa: E402

JST = timezone(timedelta(hours=9))


def make_weather(start_date, days=9):
    """Open-Meteo の応答のうち、こちらが使う形だけを作る。"""
    d = [(start_date + timedelta(days=i)).strftime("%Y-%m-%d")
         for i in range(days)]
    return {
        "timezone": "Asia/Tokyo",
        "current": {"time": d[0] + "T10:00", "temperature_2m": 21.4,
                    "weather_code": 2, "relative_humidity_2m": 58,
                    "wind_speed_10m": 11.2, "apparent_temperature": 20.1},
        "daily": {
            "time": d,
            "weather_code": [2] * days,
            "temperature_2m_max": [23] * days,
            "temperature_2m_min": [14] * days,
            "precipitation_probability_max": [10] * days,
            "sunrise": [x + "T05:40" for x in d],
            "sunset": [x + "T17:10" for x in d],
        },
    }


class TestStripLocation(unittest.TestCase):
    """公開される data.json に座標を混ぜない。

    リポジトリも data.json も誰でも読める。Open-Meteo の応答には
    問い合わせたグリッド点の座標と標高が入っている。
    """

    def test_座標と標高を落とす(self):
        d = fd.strip_location({
            "latitude": 35.85, "longitude": 139.8125, "elevation": 3.0,
            "generationtime_ms": 0.3, "utc_offset_seconds": 32400,
            "current": {"temperature_2m": 20},
        })
        for k in ("latitude", "longitude", "elevation",
                  "generationtime_ms", "utc_offset_seconds"):
            self.assertNotIn(k, d, f"{k} が残っている")

    def test_必要なものは消さない(self):
        d = fd.strip_location({"current": {"temperature_2m": 20},
                               "daily": {"time": ["2026-10-10"]},
                               "timezone": "Asia/Tokyo"})
        self.assertEqual(sorted(d), ["current", "daily", "timezone"])

    def test_入っていなくても落ちない(self):
        self.assertEqual(fd.strip_location({}), {})


class TestComputeDates(unittest.TestCase):
    """何日ぶんとして作るか。

    0 時ちょうどに作り始めるとビルドが間に合わないので、23:50 に
    翌日ぶんを先に作る。ここを間違えると画面の日付が 1 日ずれる。
    """

    def dates(self, h, m):
        return fd.compute_dates(datetime(2026, 10, 10, h, m, tzinfo=JST))

    def test_昼のビルドは当日ぶん(self):
        o = self.dates(10, 0)
        self.assertEqual(o["day_offset"], 0)
        self.assertEqual(o["for_date"], "2026-10-10")
        self.assertEqual(o["generated"], "2026-10-10T10:00")

    def test_2350のビルドは翌日ぶん(self):
        # 23:50 + 20分 = 00:10 → 日付をまたぐ
        o = self.dates(23, 50)
        self.assertEqual(o["day_offset"], 1)
        self.assertEqual(o["for_date"], "2026-10-11")
        # generated は作った時刻のまま（まだ 10/10）
        self.assertEqual(o["generated"], "2026-10-10T23:50")

    def test_2330はまだ当日ぶん(self):
        # 23:30 + 20分 = 23:50 → またがない
        o = self.dates(23, 30)
        self.assertEqual(o["day_offset"], 0)
        self.assertEqual(o["for_date"], "2026-10-10")

    def test_切り替わりの境目(self):
        # LOOKAHEAD_MIN を変えたときに、ここが意図どおり動くかを見る
        edge = 24 * 60 - fd.LOOKAHEAD_MIN          # またぎ始める時刻（分）
        before = self.dates((edge - 1) // 60, (edge - 1) % 60)
        after = self.dates(edge // 60, edge % 60)
        self.assertEqual(before["day_offset"], 0)
        self.assertEqual(after["day_offset"], 1)

    def test_0時すぎは当日ぶん(self):
        o = fd.compute_dates(datetime(2026, 10, 11, 0, 2, tzinfo=JST))
        self.assertEqual(o["day_offset"], 0)
        self.assertEqual(o["for_date"], "2026-10-11")

    def test_月をまたぐ(self):
        o = fd.compute_dates(datetime(2026, 10, 31, 23, 50, tzinfo=JST))
        self.assertEqual(o["for_date"], "2026-11-01")


class TestReusePrevWeather(unittest.TestCase):
    """天気が取れなかったときに、直前に公開したぶんで埋める。

    2026-10-10 10:01 のビルドで Open-Meteo が HTTP 503 を返し、
    天気の枠が 1 時間ぶん消えた。その埋め合わせ。

    一番こわいのは「古いものを使うこと」ではなく
    「日付の並びがずれたものを使うこと」。1 日ずれた予報を、
    それと分からない形で出してしまう。
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "prev_data.json")
        self._orig_path = fd.PREV_PATH
        self._orig_dt = fd.datetime
        fd.PREV_PATH = self.path
        # 「今」を 2026-10-10 10:25 に固定する
        self.now = datetime(2026, 10, 10, 10, 25, tzinfo=JST)
        test = self

        class FixedDatetime(datetime):
            @classmethod
            def now(cls, tz=None):
                return test.now if tz is None else test.now.astimezone(tz)
        fd.datetime = FixedDatetime

    def tearDown(self):
        fd.PREV_PATH = self._orig_path
        fd.datetime = self._orig_dt

    def write_prev(self, **over):
        prev = {
            "generated": "2026-10-10T10:00",
            "for_date": "2026-10-10",
            "day_offset": 0,
            "weather": make_weather(self.now.date()),
        }
        prev.update(over)
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(prev, f, ensure_ascii=False)

    @staticmethod
    def out(for_date="2026-10-10", day_offset=0):
        return {"for_date": for_date, "day_offset": day_offset,
                "weather": None}

    # --- 埋める場合 -------------------------------------------------

    def test_同じ日の25分前なら埋める(self):
        self.write_prev()
        o = self.out()
        note = fd.reuse_prev_weather(o)
        self.assertIsNotNone(note)
        self.assertIsNotNone(o["weather"])
        self.assertEqual(o["weather_as_of"], "2026-10-10T10:00")

    def test_2350のビルドは起点が合えば埋める(self):
        # 23:50 のビルドは for_date=翌日 / day_offset=1。
        # 直前ぶんの daily は当日起点なので daily[1] が翌日になり、一致する。
        self.write_prev()
        o = self.out(for_date="2026-10-11", day_offset=1)
        self.assertIsNotNone(fd.reuse_prev_weather(o))
        self.assertIsNotNone(o["weather"])

    def test_埋めた天気にも座標の除去をかける(self):
        w = make_weather(self.now.date())
        w.update(latitude=35.85, longitude=139.8125, elevation=3.0)
        self.write_prev(weather=w)
        o = self.out()
        fd.reuse_prev_weather(o)
        for k in ("latitude", "longitude", "elevation"):
            self.assertNotIn(k, o["weather"], f"{k} が公開物に残る")

    # --- 埋めない場合 -----------------------------------------------

    def test_0時すぎに2350のぶんは使わない(self):
        """これが一番の要点。

        0 時すぎのビルドは for_date=当日 / day_offset=0。
        直前の 23:50 のぶんは daily が前日起点なので daily[0] は前日になる。
        generated の新しさ（12分前）だけで判断すると、
        1 日ずれた予報を出してしまう。
        """
        self.now = datetime(2026, 10, 11, 0, 2, tzinfo=JST)
        self.write_prev(generated="2026-10-10T23:50",
                        for_date="2026-10-11", day_offset=1,
                        weather=make_weather(datetime(2026, 10, 10).date()))
        o = self.out(for_date="2026-10-11", day_offset=0)
        self.assertIsNone(fd.reuse_prev_weather(o))
        self.assertIsNone(o["weather"])
        self.assertNotIn("weather_as_of", o)

    def test_古すぎるものは使わない(self):
        self.write_prev(generated="2026-10-10T06:00")   # 265分前
        o = self.out()
        self.assertIsNone(fd.reuse_prev_weather(o))
        self.assertIsNone(o["weather"])

    def test_上限ちょうどは使う_1分超えたら使わない(self):
        ok = self.now - timedelta(minutes=fd.STALE_MAX_MIN)
        self.write_prev(generated=ok.strftime("%Y-%m-%dT%H:%M"))
        self.assertIsNotNone(fd.reuse_prev_weather(self.out()))

        ng = self.now - timedelta(minutes=fd.STALE_MAX_MIN + 1)
        self.write_prev(generated=ng.strftime("%Y-%m-%dT%H:%M"))
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_未来の時刻は使わない(self):
        # 端末やランナーの時計がずれている場合の保険
        self.write_prev(generated="2026-10-10T23:00")
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_直前ぶんにも天気が無い(self):
        self.write_prev(weather=None)
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_天気の形が違う(self):
        self.write_prev(weather={"current": {"temperature_2m": 20}})  # daily 無し
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_ファイルが無い(self):
        fd.PREV_PATH = os.path.join(self.dir, "ない.json")
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_壊れたJSON(self):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("{これはJSONではない")
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_generatedが読めない(self):
        self.write_prev(generated="いつか")
        self.assertIsNone(fd.reuse_prev_weather(self.out()))

    def test_day_offsetが配列の外(self):
        self.write_prev(weather=make_weather(self.now.date(), days=1))
        o = self.out(for_date="2026-10-11", day_offset=1)
        self.assertIsNone(fd.reuse_prev_weather(o))


class TestParseDateValueCsv(unittest.TestCase):
    """「日付,値」の CSV の解析。日経と FRED で使う。"""

    def test_普通に読める(self):
        v, last = fd.parse_date_value_csv(
            "DATE,VALUE\n2026-10-08,69042.11\n2026-10-09,69030.92\n", "試験")
        self.assertEqual(v, [69042.11, 69030.92])
        self.assertEqual(last, "2026-10-09")

    def test_FREDの欠損記号を飛ばす(self):
        v, last = fd.parse_date_value_csv(
            "DATE,VALUE\n2026-10-07,.\n2026-10-08,100.0\n", "試験")
        self.assertEqual(v, [100.0])
        self.assertEqual(last, "2026-10-08")

    def test_末尾の注記行を飛ばす(self):
        # 日経社の CSV は末尾に注記が入る
        v, last = fd.parse_date_value_csv(
            "日付,終値\n2026-10-09,69030.92\n"
            "※この統計は日本経済新聞社の著作物です\n", "試験")
        self.assertEqual(v, [69030.92])
        self.assertEqual(last, "2026-10-09")

    def test_CRLFでも読める(self):
        v, _ = fd.parse_date_value_csv(
            "DATE,VALUE\r\n2026-10-09,1.5\r\n", "試験")
        self.assertEqual(v, [1.5])

    def test_行が足りなければ失敗させる(self):
        # 黙って空を返すと、画面に「--」が出たまま原因が分からなくなる
        with self.assertRaises(RuntimeError):
            fd.parse_date_value_csv("DATE,VALUE\n", "試験")

    def test_数値が1つも無ければ失敗させる(self):
        with self.assertRaises(RuntimeError):
            fd.parse_date_value_csv("DATE,VALUE\n2026-10-09,.\n", "試験")

    def test_bot避けのHTMLが返ってきた場合(self):
        # Stooq はデータセンターの IP に HTML を返すことがある。
        # それを数値として読んでしまわないこと。
        with self.assertRaises(RuntimeError):
            fd.parse_date_value_csv(
                "<!DOCTYPE html>\n<html><body>Access denied</body></html>\n",
                "試験")


if __name__ == "__main__":
    unittest.main(verbosity=2)
