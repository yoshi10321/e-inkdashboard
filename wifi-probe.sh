#!/bin/sh
#
# フレームワークを止めたまま Wi-Fi を「入れられるか」を調べるスクリプト（第2版）
# ------------------------------------------------------------------
# 第1版（10/10 04:56）で分かったこと:
#   - wifid はフレームワークを止めても同じ PID で生き残る（4593）
#   - com.lab126.wifid は LIPC バスに残り、cmConnect も見えている
#
# 第1版の失敗:
#   - 調査開始時点で Wi-Fi が既に切れていた（wlan0 が存在しない）ため、
#     SSID が読めず cmConnect を一度も試せなかった
#   - currentEssid は型が Has（ハッシュ）で lipc-get-prop では読めない
#
# そこでこの版は順番を変える:
#   【A】フレームワークあり → 普通に Wi-Fi を入れ、つながった状態で
#        iwconfig から SSID を確保する（ここが第1版で欠けていた）
#   【B】Wi-Fi を切り、フレームワークを止め、その状態で入れ直せるか
#        3通り試す。欲しい答えはここ。
#
# 3通りを「SSID の要らないものから」順に試す。
#   B-1  lipc-set-prop com.lab126.wifid enable 1    （保存済みプロファイルに自動接続）
#   B-2  lipc-set-prop com.lab126.cmd  wirelessEnable 1  （従来の方法）
#   B-3  lipc-set-prop com.lab126.wifid cmConnect <SSID> （名指し）
# どれか1つでも wget まで通れば、UI を二度と起動せずに済む。
#
# 【使い方】
#   Kindle の documents フォルダに置き、本として開く。4〜5分かかる。
#   結果は /mnt/us/wifi-probe.log に書かれる。
#   終わると UI が戻る（ホーム画面が出たら後始末まで完走した印）。
#
# 【安全性】
#   保存済みの Wi-Fi 設定は変更しない。消すのは接続状態だけ。
#   途中で失敗しても trap でフレームワークを戻す。
#   それでも駄目なら電源ボタン長押しで再起動すれば元通りになる。
# ------------------------------------------------------------------

OUT=/mnt/us/wifi-probe.log
URL="https://yoshi10321.github.io/e-inkdashboard/data.json"

exec >/dev/null 2>&1

say() { echo "$(date '+%H:%M:%S') $*" >> "$OUT"; }
run() {
    echo "--- $* ---" >> "$OUT"
    "$@" >> "$OUT" 2>&1
    echo "   (終了コード $?)" >> "$OUT"
}

fw_stop() {
    if [ -x /etc/init.d/framework ]; then /etc/init.d/framework stop
    else stop lab126_gui; fi
}
fw_start() {
    if [ -x /etc/init.d/framework ]; then /etc/init.d/framework start
    else start lab126_gui; fi
}

# 何があってもフレームワークは戻す
FW_DOWN=0
trap 'if [ "$FW_DOWN" = 1 ]; then say "!! 中断されたのでフレームワークを戻す"; fw_start; fi; exit' INT TERM EXIT

# 現在の SSID を取る。iwconfig の ESSID:"..." から拾うのが一番確実。
get_ssid() {
    iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p'
}

# 接続されるまで最大 secs 秒待つ。cmState と wlan0 の両方を記録する。
wait_connected() {
    _label="$1"; _max="$2"; _i=0
    while [ "$_i" -lt "$_max" ]; do
        _st=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
        _ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
        say "  [$_label] ${_i}s  cmState=${_st:-?}  IP=${_ip:-なし}"
        if [ "$_st" = "CONNECTED" ] && [ -n "$_ip" ]; then
            say "  [$_label] 接続できた（${_i}秒）"
            return 0
        fi
        sleep 3
        _i=$(( _i + 3 ))
    done
    say "  [$_label] ${_max}秒 待っても接続できなかった"
    return 1
}

# 実際に通信できるか。これが通らなければ意味がない。
try_wget() {
    _label="$1"
    rm -f /tmp/probe.bin
    if wget -q -T 20 --no-check-certificate -O /tmp/probe.bin \
            "${URL}?t=$(date +%s)"; then
        say "  [$_label] ★ 通信できた（$(wc -c < /tmp/probe.bin) bytes）"
        rm -f /tmp/probe.bin
        return 0
    fi
    say "  [$_label] 通信できなかった"
    rm -f /tmp/probe.bin
    return 1
}

: > "$OUT"
say "===== 第2版 調査開始 ====="
say "ファームウェア: $(cat /etc/prettyversion.txt 2>/dev/null || echo 不明)"
say "電池: $(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)%"

# ------------------------------------------------------------------
say ""
say "【A】フレームワークあり: 普通に Wi-Fi を入れて SSID を確保する"
# ------------------------------------------------------------------

say "入れる前の状態"
run lipc-get-prop com.lab126.wifid cmState
# feelingLuckyProfile は Str なので読める。保存済みプロファイルの手がかり。
run lipc-get-prop com.lab126.wifid feelingLuckyProfile
run lipc-get-prop com.lab126.wifid profileCount

run lipc-set-prop com.lab126.cmd wirelessEnable 1
wait_connected "A" 60

run iwconfig wlan0
run ifconfig wlan0
run lipc-get-prop com.lab126.wifid signalStrength

SSID=$(get_ssid)
if [ -n "$SSID" ]; then
    say "SSID を確保した（長さ ${#SSID} 文字）"
    # ログを人に見せるので SSID 本体は書かない。B-3 で使うだけ。
    echo "$SSID" > /tmp/probe.ssid
else
    say "SSID が取れなかった。B-3 は飛ばす"
fi

try_wget "A"

# ------------------------------------------------------------------
say ""
say "【B】Wi-Fi を切り、フレームワークを止めた状態で入れ直せるか"
# ------------------------------------------------------------------

say "Wi-Fi を切る"
run lipc-set-prop com.lab126.cmd wirelessEnable 0
sleep 8
run lipc-get-prop com.lab126.wifid cmState

say "フレームワークを止める"
fw_stop
FW_DOWN=1
sleep 10

say "止めた直後"
run lipc-get-prop com.lab126.wifid cmState
say "wifid の PID: $(ps 2>/dev/null | grep -w wifid | grep -v grep)"
say "cmd の PID:   $(ps 2>/dev/null | grep -w cmd | grep -v grep)"

# --- B-1 -----------------------------------------------------------
say ""
say "[B-1] lipc-set-prop com.lab126.wifid enable 1"
run lipc-set-prop com.lab126.wifid enable 1
if wait_connected "B-1" 60; then
    try_wget "B-1" && say "[B-1] 成功"
else
    run dmesg
fi

# --- B-2 -----------------------------------------------------------
say ""
say "[B-2] lipc-set-prop com.lab126.cmd wirelessEnable 1（従来の方法）"
run lipc-set-prop com.lab126.cmd wirelessEnable 1
if wait_connected "B-2" 60; then
    try_wget "B-2" && say "[B-2] 成功"
fi

# --- B-3 -----------------------------------------------------------
say ""
say "[B-3] lipc-set-prop com.lab126.wifid cmConnect <SSID>"
if [ -s /tmp/probe.ssid ]; then
    SSID=$(cat /tmp/probe.ssid)
    # 念のため scan を先に走らせる
    run lipc-set-prop com.lab126.wifid scan 1
    sleep 10
    say "cmConnect を呼ぶ"
    lipc-set-prop com.lab126.wifid cmConnect "$SSID" >> "$OUT" 2>&1
    say "   (終了コード $?)"
    if wait_connected "B-3" 60; then
        try_wget "B-3" && say "[B-3] 成功"
    fi
else
    say "SSID が無いので飛ばす"
fi

say ""
say "参考: この時点の wlan0"
run iwconfig wlan0
run ifconfig wlan0

# ------------------------------------------------------------------
say ""
say "【C】後始末"
# ------------------------------------------------------------------

rm -f /tmp/probe.ssid
say "フレームワークを戻す"
fw_start
FW_DOWN=0
sleep 5
run lipc-get-prop com.lab126.wifid cmState

say "===== 調査終了 ====="
say "この結果（/mnt/us/wifi-probe.log）を見せてください"

trap - INT TERM EXIT
