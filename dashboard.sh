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

# 画面の向き
#   portrait  : 端末は縦向きのまま。回転済みの画像を表示するので、
#               Kindle 本体を横に倒して置く。（確実に動く）
#   landscape : 端末の画面自体を横向きに設定し、回転なしの画像を表示する。
#               バッテリー表示の文字も正しい向きになる。
#               ただし機種・ファームによっては向きの変更が効かない。
ORIENTATION="landscape"

# 画面を横向きにするときの回転方向。landscape が傾いて見えたら
# "L" と "R" を入れ替えて試すこと。
LANDSCAPE_DIR="L"

# 表示する画像の URL（ORIENTATION に応じて自動で選ぶ）
IMG_URL_PORTRAIT="https://yoshi10321.github.io/e-inkdashboard/dash.png"
IMG_URL_LANDSCAPE="https://yoshi10321.github.io/e-inkdashboard/dash-land.png"

# 更新間隔（秒）。3600 = 1時間
INTERVAL=3600

# バッテリー残量を画面の隅に重ねて表示するか（1=する / 0=しない）
SHOW_BATTERY=1

# バッテリー表示の位置（eips の文字単位の座標。列 行）
# 画像は 90 度回転して表示しているため、この文字も 90 度傾いて出る。
# 位置が気に入らなければこの2つの数字を変えて調整すること。
BATTERY_COL=0
BATTERY_ROW=0

# 動作モード
#   awake   : サスペンドしない。動作確認用。電池はどんどん減る。
#   suspend : 更新の合間はサスペンドする。常用はこちら。
# まずは awake で画像が出ることを確認してから suspend に変えること。
MODE="awake"

# ====================================================================

if [ "$ORIENTATION" = "landscape" ]; then
    IMG_URL="$IMG_URL_LANDSCAPE"
else
    IMG_URL="$IMG_URL_PORTRAIT"
fi

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

# --- 画面の向き -----------------------------------------------------

# 端末の画面の向きを設定する。
#   U=縦（標準） / L=左回転 / R=右回転 / D=上下逆
set_orientation() {
    dir=$1
    # UI フレームワーク側の向きを変える
    lipc-set-prop com.lab126.winmgr orientationLock "$dir" 2>>"$LOG"
    rc=$?
    log "画面の向きを $dir に設定 (終了コード $rc)"
    sleep 2
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

show_image() {
    [ -f "$IMG" ] || { log "表示する画像がない"; return 1; }

    # 残像を消すために一度クリアしてから描画する
    eips -c >/dev/null 2>&1
    sleep 1
    eips -g "$IMG" >/dev/null 2>&1

    bat=$(battery_level)
    if [ -n "$bat" ]; then
        if is_charging; then mark="+"; else mark=""; fi
        log "描画完了 (電池 ${bat}%${mark})"
        if [ "$SHOW_BATTERY" = "1" ]; then
            # eips の文字描画は画像の上に重ねて書かれる
            eips "$BATTERY_COL" "$BATTERY_ROW" " ${bat}%${mark} " >/dev/null 2>&1
        fi
    else
        log "描画完了 (電池残量を取得できず)"
    fi
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
    lipc-set-prop com.lab126.winmgr orientationLock U 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# --- メインループ ---------------------------------------------------

# 画面の向きを設定する
if [ "$ORIENTATION" = "landscape" ]; then
    set_orientation "$LANDSCAPE_DIR"
else
    set_orientation "U"
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
