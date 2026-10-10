#!/bin/sh
#
# dashboard.sh のテスト。
#
# 端末が無いと動かない部分（lipc / eips / framework）はスタブに差し替えるが、
# **関数そのものは dashboard.sh から読み込む**。写しを置いてテストすると、
# 本体を直したときに写しが古いままになり、通っているのに壊れている状態になる。
#
#   sh tests/test_dashboard_sh.sh
#
# dashboard.sh は DASHBOARD_LIB が入っていると、関数定義だけしてメインループに
# 入る前に戻る。DASH_WORKDIR で作業先も差し替える。

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
ng() { FAIL=$((FAIL + 1)); echo "  NG   $1"; echo "       $2"; }

is() {   # is <説明> <実際> <期待>
    if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "期待 [$3] / 実際 [$2]"; fi
}

# 秒数を時刻に戻す。
#
# plan_next の 23:40 を 84000 秒（実際は 23:20）と書き間違えたことがある。
# そのとき「23:39 にずらす」と決め打ちで表示していたため、計算結果を見ずに
# 通してしまった。**秒数のまま比べず、必ず時刻に戻して確かめる。**
tod()  { printf '%02d:%02d:%02d' $(( ($1 % 86400) / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 )); }
secs() { echo $(( $1 * 3600 + $2 * 60 + ${3:-0} )); }

# --- スタブ ---------------------------------------------------------
# PATH の先頭に置いて、端末のコマンドを乗っ取る。

mkdir -p "$TMP/bin" "$TMP/work/documents" "$TMP/state"
export DASH_WORKDIR="$TMP/work"
export DASHBOARD_LIB=1
export STATEDIR="$TMP/state"
# スタブは別プロセスなので、渡す値は export しないと届かない。
# （UI_FALLBACK は dashboard.sh の関数が同じシェルで読むので export 不要）
SCENARIO=ok
IP_DELAY=0
export SCENARIO IP_DELAY

cat > "$TMP/bin/lipc-get-prop" <<'EOF'
#!/bin/sh
# 呼ばれ方は  lipc-get-prop com.lab126.wifid cmState  なので $1=サービス $2=プロパティ
case "$2" in
  cmState)
    # 「UI 無しでは繋がらない」場面を再現するため、UI の状態を見る
    if [ "${SCENARIO:-ok}" = "needs_ui" ] && [ ! -f "$STATEDIR/ui_up" ]; then
        echo NA; exit 0
    fi
    n=$(cat "$STATEDIR/polls" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$STATEDIR/polls"
    # 2 回目の確認で繋がる（実機は 6 秒ほど）
    [ "$n" -ge 2 ] && echo CONNECTED || echo NA ;;
  *) echo "" ;;
esac
EOF

cat > "$TMP/bin/lipc-set-prop" <<'EOF'
#!/bin/sh
echo "$*" >> "$STATEDIR/lipc_set.log"
exit 0
EOF

cat > "$TMP/bin/ifconfig" <<'EOF'
#!/bin/sh
# IP は cmState が CONNECTED になってから付く。
# 「CONNECTED になった瞬間はまだ通信できない」を再現するため、
# IP_DELAY 回ぶん遅らせられるようにしてある。
if [ "${SCENARIO:-ok}" = "needs_ui" ] && [ ! -f "$STATEDIR/ui_up" ]; then exit 0; fi
n=$(cat "$STATEDIR/polls" 2>/dev/null || echo 0)
if [ "$n" -ge $(( 2 + ${IP_DELAY:-0} )) ]; then
    echo "          inet addr:192.168.10.134  Bcast:192.168.10.255"
fi
EOF

cat > "$TMP/bin/stop" <<'EOF'
#!/bin/sh
rm -f "$STATEDIR/ui_up"
echo stop >> "$STATEDIR/fw.log"
EOF

cat > "$TMP/bin/start" <<'EOF'
#!/bin/sh
: > "$STATEDIR/ui_up"
rm -f "$STATEDIR/polls"
echo start >> "$STATEDIR/fw.log"
EOF

for c in initctl eips wget od gasgauge-info; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"
done

# sleep も潰す。
# 接続待ちは 2 秒 × 30 回、UI の起動待ちは 15 秒ある。実時間で待つと
# テストに数分かかり、誰も回さなくなる。確かめたいのは待ち時間ではなく
# 「何回ポーリングしてどう判断するか」なので、待ちだけ取り除く。
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin"/*
PATH="$TMP/bin:$PATH"
export PATH

reset_state() {
    rm -f "$STATEDIR"/* 2>/dev/null
    FRAMEWORK_STOPPED=1          # 起動時に止めた後の状態から始める
    UI_FALLBACK_COUNT=0
}

# dashboard.sh を読み込む（メインループには入らない）
# shellcheck disable=SC1090
. "$ROOT/dashboard.sh"

# 待ち時間を詰める。テストに 1 分もかけない。
NET_SETTLE=0

echo
echo "=== 読み込み ==="
is "メインループに入らずに関数だけ読める" "$(command -v plan_next >/dev/null && echo yes)" "yes"
is "作業先を差し替えられる" "$WORKDIR" "$TMP/work"

# --- plan_next ------------------------------------------------------
# 一度バグらせた箇所。秒ではなく時刻に戻して確かめる。

echo
echo "=== plan_next: 次に起きる時刻 ==="
INTERVAL=3600
UPDATE_AT_MIDNIGHT=1
MIDNIGHT_OFFSET=120
BASE=1760000000               # 基準の epoch。値自体に意味は無い

check_next() {   # check_next <説明> <時> <分> <期待する時刻>
    _t=$(secs "$2" "$3")
    _n=$(plan_next "$BASE" "$_t")
    _got=$(tod $(( (_t + (_n - BASE)) % 86400 )))
    is "$1（$(printf '%02d:%02d' "$2" "$3") に決める）" "$_got" "$4"
}

check_next "昼は1時間後" 10 0 "11:00:00"
check_next "22:00 の次は 23:00" 22 0 "23:00:00"
# 23:00 の 1 時間後はちょうど 00:00。窓は 23:40〜24:00 の手前までなので、
# これは窓の中ではない。0 時を回っていれば 23:50 に出来た翌日ぶんを
# 取ってよいので、ずらさないのが正しい。
check_next "23:00 の次はちょうど 0時（窓の外なのでずらさない）" 23 0 "00:00:00"
# 窓の入口は 23:40 なので、1 時間前の 22:40 が境目になる。
#
# ここは一度しくじっている（23:40 を 84000 秒＝実際は 23:20 と書いた）。
# **境目の手前と後の両方を見ないと、定数を間違えても気づけない。**
# 22:30 だけを見て「ずらした」ことに満足すると、入口が 23:20 に
# なっていても通ってしまう。
# 22:39 は、ずらさなくても自然に 23:39 になる（窓の 1 分手前）
check_next "22:39 の次は自然に 23:39（ずらしではない）" 22 39 "23:39:00"
check_next "22:30 の次は 23:30（ずらしてはいけない）" 22 30 "23:30:00"
check_next "22:20 の次は 23:20（ずらしてはいけない）" 22 20 "23:20:00"
check_next "22:40 の次は窓に当たるので 23:39 へ" 22 40 "23:39:00"
check_next "22:45 の次も窓に当たるので 23:39 へ" 22 45 "23:39:00"
# 23:39 から 1 時間後は 00:39。0 時すぎの更新が先に来るので 00:02。
check_next "23:39 の次は 0時すぎ" 23 39 "00:02:00"
check_next "23:45 の次も 0時すぎ" 23 45 "00:02:00"
# 0:02 に起きた直後は、次は通常どおり 1 時間後
check_next "0:02 の次は 1:02" 0 2 "01:02:00"
# 0 時ちょうどに起きた場合は、まず 0:02 を取りに行く
check_next "0:00 の次は 0:02" 0 0 "00:02:00"

echo
echo "--- 窓（23:40〜24:00）に落ちないこと ---"
hh=0
while [ "$hh" -lt 24 ]; do
    for mm in 0 15 30 45; do
        t=$(secs "$hh" "$mm")
        n=$(plan_next "$BASE" "$t")
        nt=$(( (t + (n - BASE)) % 86400 ))
        if [ "$nt" -ge 85200 ] && [ "$nt" -lt 86400 ]; then
            ng "窓を避ける" "$(printf '%02d:%02d' "$hh" "$mm") の次が $(tod "$nt") で窓の中"
            hh=99; break
        fi
        if [ "$n" -le "$BASE" ]; then
            ng "次の時刻が未来" "$(printf '%02d:%02d' "$hh" "$mm") の次が過去や同時刻"
            hh=99; break
        fi
    done
    hh=$((hh + 1))
done
[ "$hh" = "24" ] && ok "24時間×4点すべてで、窓を避け、かつ未来の時刻になる"

echo
echo "--- 0時の更新を切った場合 ---"
UPDATE_AT_MIDNIGHT=0
n=$(plan_next "$BASE" "$(secs 23 0)")
is "窓も0時も効かず、素直に1時間後" "$(tod $(( ($(secs 23 0) + (n - BASE)) % 86400 )))" "00:00:00"
UPDATE_AT_MIDNIGHT=1

# --- wait_online ----------------------------------------------------

echo
echo "=== wait_online: 繋がったと判断する条件 ==="
reset_state
SCENARIO=ok; IP_DELAY=0
if wait_online; then ok "CONNECTED かつ IP ありなら成功"; else ng "CONNECTED かつ IP ありなら成功" "失敗した"; fi

reset_state
# CONNECTED にはなるが IP がいつまでも付かない場合
cat > "$TMP/bin/ifconfig" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/ifconfig"
if wait_online; then
    ng "IP が無いうちは成功にしない" "成功してしまった（CONNECTED だけで通している）"
else
    ok "IP が無いうちは成功にしない"
fi
# 戻す
cat > "$TMP/bin/ifconfig" <<'EOF'
#!/bin/sh
if [ "${SCENARIO:-ok}" = "needs_ui" ] && [ ! -f "$STATEDIR/ui_up" ]; then exit 0; fi
n=$(cat "$STATEDIR/polls" 2>/dev/null || echo 0)
if [ "$n" -ge $(( 2 + ${IP_DELAY:-0} )) ]; then
    echo "          inet addr:192.168.10.134  Bcast:192.168.10.255"
fi
EOF
chmod +x "$TMP/bin/ifconfig"

# --- 1 周ぶんの通信 -------------------------------------------------
#
# fetch_cycle は dashboard.sh の本物を呼ぶ。順序を写してここに書くと、
# 本体を直したときに写しが古いままになり、通っているのに壊れる。
# 外に出ていく fetch_all だけ差し替える。

fetch_all() { echo called >> "$STATEDIR/fetch.log"; }

echo
echo "=== 通信: UI を起こすかどうか ==="

reset_state
SCENARIO=ok; UI_FALLBACK=1
cyc=1; while [ "$cyc" -le 3 ]; do rm -f "$STATEDIR/polls"; fetch_cycle; cyc=$((cyc + 1)); done
is "繋がる場合、3周まわして接続できる" "$ONLINE" "1"
is "繋がる場合、UI は一度も起きない" "$(grep -c start "$STATEDIR/fw.log" 2>/dev/null || echo 0)" "0"
is "繋がる場合、フォールバックの回数は 0" "$UI_FALLBACK_COUNT" "0"

reset_state
SCENARIO=needs_ui; UI_FALLBACK=1
cyc=1; while [ "$cyc" -le 2 ]; do rm -f "$STATEDIR/polls"; fetch_cycle; cyc=$((cyc + 1)); done
is "UI が要る場合でも接続できる" "$ONLINE" "1"
is "UI が要る場合、周回ごとに起こす" "$UI_FALLBACK_COUNT" "2"
is "UI が要る場合、描画前に止め直す" "$([ -f "$STATEDIR/ui_up" ] && echo 起きたまま || echo 止まっている)" "止まっている"
is "起こした回数と止めた回数が合う" \
   "$(grep -c start "$STATEDIR/fw.log" 2>/dev/null || echo 0)" "$(grep -c stop "$STATEDIR/fw.log" 2>/dev/null || echo 0)"

reset_state
SCENARIO=needs_ui; UI_FALLBACK=0
rm -f "$STATEDIR/polls"; fetch_cycle
is "フォールバックを切れば UI を起こさない" "$(grep -c start "$STATEDIR/fw.log" 2>/dev/null || echo 0)" "0"
is "フォールバックを切れば、繋がらないまま続行する" "$ONLINE" "0"
is "繋がらなければ取得しに行かない" \
   "$(grep -c called "$STATEDIR/fetch.log" 2>/dev/null || echo 0)" "0"

reset_state
SCENARIO=ok; UI_FALLBACK=1
rm -f "$STATEDIR/polls"; fetch_cycle
is "繋がれば 1 周につき 1 回だけ取得する" \
   "$(grep -c called "$STATEDIR/fetch.log" 2>/dev/null || echo 0)" "1"

echo
echo "=== Wi-Fi を必ず切ること ==="
reset_state
SCENARIO=ok; UI_FALLBACK=1
rm -f "$STATEDIR/polls"; fetch_cycle
is "周回の最後に wirelessEnable 0 を出す" \
   "$(tail -1 "$STATEDIR/lipc_set.log")" "com.lab126.cmd wirelessEnable 0"

# --- arm_watchdog ---------------------------------------------------

echo
echo "=== arm_watchdog: 寝落ち対策 ==="
# 実機の /sys は触れないので、関数を同じ形で読み直して差し替える
mkdir -p "$TMP/rtc0" "$TMP/rtc1"
: > "$TMP/rtc1/wakealarm"
: > "$TMP/rtc0/wakealarm"
arm_watchdog_test() {
    for rtc in "$TMP/rtc1/wakealarm" "$TMP/rtc0/wakealarm"; do
        [ -w "$rtc" ] || continue
        echo 0 > "$rtc" 2>/dev/null
        echo "+$WATCHDOG" > "$rtc" 2>/dev/null && return 0
    done
    return 1
}
arm_watchdog_test
is "書ける rtc にアラームを仕掛ける" "$(cat "$TMP/rtc1/wakealarm")" "+$WATCHDOG"
is "WATCHDOG が無効な値になっていない" "$([ "$WATCHDOG" -gt 60 ] && echo ok)" "ok"

# 片方の RTC にアラームの口が無い場合。
# chmod では再現できない（root は 444 のファイルにも書けるし、
# [ -w ] も true を返す）ので、ファイルごと消す。
rm -f "$TMP/rtc1/wakealarm"
: > "$TMP/rtc0/wakealarm"
if arm_watchdog_test; then
    is "片方が書けなくても、もう片方に仕掛ける" "$(cat "$TMP/rtc0/wakealarm")" "+$WATCHDOG"
else
    ng "片方が書けなくても、もう片方に仕掛ける" "どちらにも仕掛けられなかった"
fi

# --- round_to_5 -----------------------------------------------------

echo
echo "=== round_to_5: 電池アイコンの丸め ==="
is "87 → 85" "$(round_to_5 87)" "85"
is "88 → 90" "$(round_to_5 88)" "90"
is "0 → 0"   "$(round_to_5 0)"  "0"
is "100 → 100" "$(round_to_5 100)" "100"
is "空なら空を返す" "$(round_to_5 '')" ""

# --- log_image_age --------------------------------------------------

echo
echo "=== log_image_age: 画像が本日ぶんか ==="
TODAY=$(date '+%Y-%m-%d')
YESTERDAY=$(date -d yesterday '+%Y-%m-%d' 2>/dev/null \
            || date -v-1d '+%Y-%m-%d' 2>/dev/null || echo "2000-01-01")

fake_wget() {   # 本文を返す wget に差し替える
    cat > "$TMP/bin/wget" <<EOF
#!/bin/sh
printf '%s' '$1'
EOF
    chmod +x "$TMP/bin/wget"
}

fake_wget "{\"generated\":\"${TODAY}T10:00\",\"for_date\":\"${TODAY}\"}"
log_image_age
is "for_date が今日なら本日ぶん" "$IMAGE_IS_TODAY" "1"

fake_wget "{\"generated\":\"${TODAY}T23:50\",\"for_date\":\"${YESTERDAY}\"}"
log_image_age
is "for_date が昨日なら本日ぶんでない" "$IMAGE_IS_TODAY" "0"

# for_date が無い古い形式では generated で代用する
fake_wget "{\"generated\":\"${TODAY}T10:00\"}"
log_image_age
is "for_date が無ければ generated を見る" "$IMAGE_IS_TODAY" "1"

fake_wget ""
log_image_age
is "取得できなければ本日ぶんと見なさない" "$IMAGE_IS_TODAY" "0"

# --- まとめ ---------------------------------------------------------

echo
echo "===================================="
echo "  成功 $PASS 件 / 失敗 $FAIL 件"
echo "===================================="
[ "$FAIL" -eq 0 ] || exit 1
