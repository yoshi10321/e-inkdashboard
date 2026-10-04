#!/bin/sh
#
# Kindle ダッシュボード表示スクリプト
# ------------------------------------------------------------------
# GitHub Pages に置いた dash.png を定期的に取得し、画面に描画する。
# 更新の合間は端末をサスペンドさせて電池を節約する。
#
# 【置き場所】
#   Kindle を USB 接続し、このファイルを documents フォルダに置く。
#   ライブラリに「dashboard」という本として現れるので、開くと実行される。
#
# 【設置の向き】
#   dash.png は反時計回りに 90 度回してある。倒して置くと正しく読める。
#
# 【止め方】
#   ・/mnt/us/documents/dashboard.stop という空ファイルを作る（次の更新時に終了）
#   ・または電源ボタン長押し → 再起動
#
# 【UI が戻らなくなったら】
#   UI を止めているだけなので、電源ボタン長押しで再起動すれば元に戻る。
#
# 【ログ】
#   /mnt/us/dashboard.log に記録される。USB 接続すれば PC から読める。
# ------------------------------------------------------------------

# ===== 設定 =========================================================

# 表示する画像の URL
IMG_URL="https://yoshi10321.github.io/e-inkdashboard/dash.png"

# 更新間隔（秒）。3600 = 1時間
INTERVAL=3600

# 動作モード
#   awake   : サスペンドしない。動作確認用。電池はどんどん減る。
#   suspend : 更新の合間はサスペンドする。常用はこちら。
MODE="awake"

# Kindle の UI（ホーム画面・ステータスバー）を止めるか
#   1 : 止める。時計や電池アイコンが一切描かれなくなり、省電力にもなる。
#       止めている間は本を読んだり設定を開いたりはできない（再起動で戻る）。
#   0 : 止めない。画面の端に Kindle 標準のステータスバーが残る。
STOP_FRAMEWORK=1

# バッテリー残量のアイコンを重ねて表示するか
SHOW_BATTERY=1
BAT_URL_BASE="https://yoshi10321.github.io/e-inkdashboard/bat"

# ====================================================================

WORKDIR=/mnt/us
IMG="$WORKDIR/dashboard.png"
LOG="$WORKDIR/dashboard.log"
STOPFILE="$WORKDIR/documents/dashboard.stop"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# ログが肥大化しないよう、起動時に大きければ切り詰める
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 100000 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "===== 起動 (mode=$MODE interval=${INTERVAL}s framework停止=$STOP_FRAMEWORK) ====="

# スクリプトの標準出力・標準エラーはそのまま画面に描かれてしまい、
# eips が出す内部メッセージがダッシュボードの上に重なる。すべて捨てる。
# （log() は直接ファイルへ書くので、この後もログは残る）
exec >/dev/null 2>&1

# --- UI フレームワークの停止と再開 ----------------------------------
# ファームウェアによって init スクリプト方式と upstart 方式があるので
# 両方試す。止めると時計やステータスバーが一切描かれなくなる。

FRAMEWORK_STOPPED=0

stop_framework() {
    [ "$STOP_FRAMEWORK" = "1" ] || return 0
    if [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework stop
    else
        stop lab126_gui   2>/dev/null || initctl stop lab126_gui 2>/dev/null
        stop framework    2>/dev/null || initctl stop framework  2>/dev/null
    fi
    FRAMEWORK_STOPPED=1
    log "UI フレームワークを停止した"
    sleep 3
}

start_framework() {
    [ "$FRAMEWORK_STOPPED" = "1" ] || return 0
    if [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework start
    else
        start lab126_gui  2>/dev/null || initctl start lab126_gui 2>/dev/null
        start framework   2>/dev/null || initctl start framework  2>/dev/null
    fi
    FRAMEWORK_STOPPED=0
    log "UI フレームワークを再開した"
}

# --- Wi-Fi 制御 -----------------------------------------------------
# フレームワークを止めると lipc の com.lab126.cmd が使えなくなるため、
# その場合は wlan0 を直接操作する。

wifi_on() {
    if [ "$FRAMEWORK_STOPPED" = "1" ]; then
        ifconfig wlan0 up 2>/dev/null
        wpa_cli -i wlan0 reassociate 2>/dev/null
    else
        lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
    fi
}

wifi_off() {
    # サスペンド中は無線も落ちるので、フレームワーク停止時は何もしない
    [ "$FRAMEWORK_STOPPED" = "1" ] && return 0
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
}

# 接続が確立するまで最大 60 秒待つ
wait_online() {
    i=0
    while [ $i -lt 30 ]; do
        if [ "$FRAMEWORK_STOPPED" = "1" ]; then
            # lipc が使えないので、実際に通信できるかどうかで判断する
            if wget -q --no-check-certificate --spider -T 5 "$IMG_URL" 2>/dev/null; then
                log "ネットワーク疎通 OK (${i}回目の確認)"
                return 0
            fi
        else
            state=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
            if [ "$state" = "CONNECTED" ]; then
                log "Wi-Fi 接続 OK (${i}回目の確認)"
                return 0
            fi
        fi
        sleep 2
        i=$((i + 1))
    done
    log "ネットワーク接続タイムアウト"
    return 1
}

# --- 画像の取得 -----------------------------------------------------

fetch_image() {
    url="${IMG_URL}?t=$(date +%s)"   # キャッシュ回避
    if wget -q --no-check-certificate -O "$IMG.tmp" "$url" 2>>"$LOG"; then
        # エラーページを掴んでいないか簡易チェック
        if [ -s "$IMG.tmp" ] && head -c 4 "$IMG.tmp" | grep -q "PNG"; then
            mv "$IMG.tmp" "$IMG"
            log "取得成功 ($(wc -c < "$IMG") bytes)"
            return 0
        fi
        log "取得したファイルが PNG ではない"
    else
        log "wget 失敗"
    fi
    rm -f "$IMG.tmp"
    return 1
}

# --- バッテリー -----------------------------------------------------

# 残量（%）を取得する。環境によって使える手段が違うので順に試し、
# どれが効いたかをログに残す。
battery_level() {
    # 1) sysfs。フレームワークにも lipc にも依存しないので最も確実。
    for f in /sys/class/power_supply/*/capacity; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null | tr -dc '0-9')
        if [ -n "$v" ]; then
            log "電池残量の取得元: $f"
            echo "$v"; return
        fi
    done

    # 2) gasgauge-info。-s が百分率、-c は機種により mAh を返すことがある。
    v=$(gasgauge-info -s 2>/dev/null | tr -dc '0-9')
    if [ -n "$v" ]; then
        log "電池残量の取得元: gasgauge-info -s"
        echo "$v"; return
    fi

    # 3) lipc（フレームワーク停止中は使えないことがある）
    v=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null | tr -dc '0-9')
    if [ -n "$v" ]; then
        log "電池残量の取得元: lipc powerd"
        echo "$v"; return
    fi

    echo ""
}

is_charging() {
    [ "$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)" = "1" ]
}

# 用意してあるアイコンに合わせて 5% 刻みに丸める
round_to_5() {
    [ -z "$1" ] && { echo ""; return; }
    echo $(( ($1 + 2) / 5 * 5 ))
}

# バッテリーアイコンを端末の左上に重ねて描く。
# dash.png は反時計回りに回してあるので、左上＝横向き設置時の画面上部にあたる。
draw_battery() {
    [ "$SHOW_BATTERY" = "1" ] || return 0

    bat=$(battery_level)
    [ -n "$bat" ] || { log "電池残量を取得できず"; return 1; }

    if is_charging; then log "電池 ${bat}%（充電中）"; else log "電池 ${bat}%"; fi

    lv=$(round_to_5 "$bat")
    [ "$lv" -gt 100 ] 2>/dev/null && lv=100
    [ "$lv" -lt 0 ] 2>/dev/null && lv=0

    bimg="$WORKDIR/bat_${lv}.png"
    if [ ! -f "$bimg" ]; then
        burl="$BAT_URL_BASE/${lv}.png"
        log "バッテリーアイコンを取得: $burl"
        wget -q --no-check-certificate -O "$bimg.tmp" "$burl" 2>>"$LOG"
        if [ -s "$bimg.tmp" ] && head -c 4 "$bimg.tmp" | grep -q "PNG"; then
            mv "$bimg.tmp" "$bimg"
            log "アイコン取得成功 ($(wc -c < "$bimg") bytes)"
        else
            log "アイコン取得失敗（サイズ $(wc -c < "$bimg.tmp" 2>/dev/null) bytes）"
            rm -f "$bimg.tmp"
            return 1
        fi
    fi

    # eips は画像を左上 (0,0) に等倍で描く。小さい画像なのでその部分だけ上書きされる。
    eips -g "$bimg"
    log "バッテリーアイコンを描画した (${lv}%)"
    return 0
}

# --- 画面描画 -------------------------------------------------------

show_image() {
    [ -f "$IMG" ] || { log "表示する画像がない"; return 1; }

    eips -c          # 残像を消す
    sleep 1
    eips -g "$IMG"
    log "描画完了"

    draw_battery
    return 0
}

# --- サスペンド -----------------------------------------------------

suspend_for() {
    secs=$1
    # RTC の wakealarm に起床時刻をセットしてからサスペンドする。
    # 機種によって rtc1 だったり rtc0 だったりするので両方試す。
    for rtc in /sys/class/rtc/rtc1/wakealarm /sys/class/rtc/rtc0/wakealarm; do
        [ -w "$rtc" ] || continue
        echo 0 > "$rtc" 2>/dev/null
        if echo "+$secs" > "$rtc" 2>/dev/null; then
            log "サスペンド開始 (${secs}秒後に起床予定, $rtc)"
            echo mem > /sys/power/state 2>>"$LOG"
            log "起床"
            return 0
        fi
    done
    log "RTC が使えなかったので通常の sleep で待機"
    sleep "$secs"
}

# --- 後始末 ---------------------------------------------------------

cleanup() {
    log "===== 終了 ====="
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    start_framework
    exit 0
}
trap cleanup INT TERM

# --- メインループ ---------------------------------------------------

# UI を止める（時計・ステータスバーが描かれなくなる）
stop_framework

# UI を止めない場合、awake モードではスクリーンセーバーに入られると
# 画像が消えてしまうので抑止する
if [ "$MODE" = "awake" ] && [ "$STOP_FRAMEWORK" != "1" ]; then
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
    log "スクリーンセーバーを抑止した"
fi

while true; do
    if [ -f "$STOPFILE" ]; then
        log "停止ファイルを検出した"
        rm -f "$STOPFILE"
        cleanup
    fi

    wifi_on
    if wait_online; then
        fetch_image
    fi
    wifi_off

    show_image

    if [ "$MODE" = "suspend" ]; then
        suspend_for "$INTERVAL"
    else
        sleep "$INTERVAL"
    fi
done
