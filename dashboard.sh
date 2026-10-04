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
# 【止め方】
#   電源ボタン長押し → 再起動。または documents/dashboard.stop を作る。
#
# 【ログ】
#   /mnt/us/dashboard.log に記録される。USB 接続すればPCから読める。
# ------------------------------------------------------------------

# ===== 設定 =========================================================

# 表示する画像の URL
#   dash.png は反時計回りに90度回転済み。Kindle を「横向き」に置くと正しく読める。
#   （端末の画面の向き設定 orientationLock は第7世代では効かないため、画像側で回す）
IMG_URL="https://yoshi10321.github.io/e-inkdashboard/dash.png"

# バッテリー残量の表示
#   SHOW_BATTERY=1 のとき、残量に応じた小さな画像を端末の左上に重ねて描く。
#   dash.png は反時計回りに回してあるので、そこは横向き設置時の「画面上部（右寄り）」にあたる。
SHOW_BATTERY=1
BAT_URL_BASE="https://yoshi10321.github.io/e-inkdashboard/bat"

# Kindle 標準のステータスバー（時計など）を隠すか
HIDE_STATUS_BAR=1

# 更新間隔（秒）。3600 = 1時間
INTERVAL=3600

# バッテリー残量を画面の隅に重ねて表示するか（1=する / 0=しない）
SHOW_BATTERY=1


# 動作モード
#   awake   : サスペンドしない。動作確認用。電池はどんどん減る。
#   suspend : 更新の合間はサスペンドする。常用はこちら。
# まずは awake で画像が出ることを確認してから suspend に変えること。
MODE="awake"

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

log "===== 起動 (mode=$MODE interval=${INTERVAL}s) ====="

# スクリプトの標準出力・標準エラーはそのまま画面に描かれてしまい、
# eips が出す "PARTIAL, wave in this platform" のような内部メッセージが
# ダッシュボードの上に重なってしまう。すべて捨てる。
# （log() は直接ファイルへ書くので、この後もログは残る）
exec >/dev/null 2>&1

# --- ステータスバー -------------------------------------------------

# Kindle 標準の上部ステータスバー（時計・電池アイコンなど）の表示を切り替える。
# 1 で非表示、0 で再表示。
set_status_bar() {
    lipc-set-prop com.lab126.pillow disableEnablePillow "$1" 2>>"$LOG"
    log "ステータスバー disableEnablePillow=$1 (終了コード $?)"
}

# --- Wi-Fi 制御 -----------------------------------------------------

wifi_on() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
}

wifi_off() {
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
}

# 接続が確立するまで最大 60 秒待つ
wait_online() {
    i=0
    while [ $i -lt 30 ]; do
        state=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
        if [ "$state" = "CONNECTED" ]; then
            log "Wi-Fi 接続 OK (${i}回目の確認)"
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    log "Wi-Fi 接続タイムアウト (最後の状態: $state)"
    return 1
}

# --- 画像の取得 -----------------------------------------------------

fetch_image() {
    # キャッシュ回避のため URL にタイムスタンプを付ける
    url="${IMG_URL}?t=$(date +%s)"

    # busybox の wget を使う。--no-check-certificate は
    # 古い Kindle の証明書ストアが新しい CA を知らない場合の保険。
    if wget -q --no-check-certificate -O "$IMG.tmp" "$url" 2>>"$LOG"; then
        # 中身が PNG かどうか簡易チェック（エラーページを掴んでいないか）
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

# --- 画面描画 -------------------------------------------------------

# バッテリー残量（%）を取得する。取れなければ空文字を返す。
battery_level() {
    lvl=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    if [ -z "$lvl" ]; then
        # lipc が使えない場合のフォールバック
        lvl=$(gasgauge-info -c 2>/dev/null | tr -dc '0-9')
    fi
    echo "$lvl" | tr -dc '0-9'
}

# 充電中かどうか
is_charging() {
    st=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
    [ "$st" = "1" ]
}

# 残量を 5% 刻みに丸める（用意してある画像に合わせる）
round_to_5() {
    v=$1
    [ -z "$v" ] && { echo ""; return; }
    echo $(( (v + 2) / 5 * 5 ))
}

# バッテリー画像を取得して、端末の左上に重ねて描く。
# dash.png は反時計回りに回してあるので、左上＝横向き設置時の画面上部にあたる。
draw_battery() {
    [ "$SHOW_BATTERY" = "1" ] || return 0

    bat=$(battery_level)
    [ -n "$bat" ] || { log "電池残量を取得できず"; return 1; }

    if is_charging; then mark="（充電中）"; else mark=""; fi
    log "電池 ${bat}% ${mark}"

    lv=$(round_to_5 "$bat")
    [ "$lv" -gt 100 ] 2>/dev/null && lv=100

    bimg="$WORKDIR/bat_${lv}.png"
    if [ ! -f "$bimg" ]; then
        wget -q --no-check-certificate -O "$bimg.tmp" "$BAT_URL_BASE/${lv}.png" 2>>"$LOG"
        if [ -s "$bimg.tmp" ] && head -c 4 "$bimg.tmp" | grep -q "PNG"; then
            mv "$bimg.tmp" "$bimg"
        else
            rm -f "$bimg.tmp"
            log "バッテリー画像 ${lv}.png を取得できなかった"
            return 1
        fi
    fi

    # eips は画像を左上 (0,0) に等倍で描く。小さい画像なのでその部分だけ上書きされる。
    eips -g "$bimg" >/dev/null 2>&1
    return 0
}

show_image() {
    [ -f "$IMG" ] || { log "表示する画像がない"; return 1; }

    # 残像を消すために一度クリアしてから描画する
    eips -c >/dev/null 2>&1
    sleep 1
    eips -g "$IMG" >/dev/null 2>&1
    log "描画完了"

    draw_battery
    return 0
}

# --- サスペンド -----------------------------------------------------

suspend_for() {
    secs=$1

    # RTC の wakealarm に起床時刻をセットしてからサスペンドする。
    # rtc1 が無い機種は rtc0 を使う。
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
    lipc-set-prop com.lab126.pillow disableEnablePillow 0 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# --- メインループ ---------------------------------------------------

# Kindle 標準のステータスバーを隠す
if [ "$HIDE_STATUS_BAR" = "1" ]; then
    set_status_bar 1
fi

# awake モードではスクリーンセーバーに入られると画像が消えるので抑止する
if [ "$MODE" = "awake" ]; then
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
    log "スクリーンセーバーを抑止した"
fi

while true; do
    # 停止ファイルがあれば抜ける
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
