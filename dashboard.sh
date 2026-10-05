#!/bin/sh
#
# Kindle ダッシュボード表示スクリプト
# ------------------------------------------------------------------
# GitHub Pages に置いた画像を定期的に取得し、画面に描画する。
#
# 【重要な設計】
#   UI フレームワーク（lab126_gui）を止めるとステータスバーは消えるが、
#   同時に Wi-Fi 制御（lipc の com.lab126.cmd）も使えなくなる。
#   そのため 1 周ごとに次の順番で動かす:
#
#     1. UI を動かした状態でネットワーク作業（画像とアイコンを取得）
#     2. Wi-Fi を切る
#     3. UI を止める（ステータスバーが描かれなくなる）
#     4. 画面に描画する
#     5. 待機（サスペンド）
#
#   取得をすべて先に済ませてから UI を止めるのがポイント。
#
# 【置き場所】
#   Kindle を USB 接続し、このファイルを documents フォルダに置く。
#   ライブラリに「dashboard」という本として現れるので、開くと実行される。
#
# 【設置の向き】
#   dash.png は反時計回りに 90 度回してある。倒して置くと正しく読める。
#
# 【止め方】
#   ・/mnt/us/documents/dashboard.stop という空ファイルを作る
#   ・または電源ボタン長押し → 再起動
#
# 【画面が真っ白で反応しなくなったら】
#   UI を止めているだけなので、電源ボタンを 20〜40 秒長押しすれば再起動して戻る。
#
# 【ログ】
#   /mnt/us/dashboard.log に記録される。USB 接続すれば PC から読める。
# ------------------------------------------------------------------

# ===== 設定 =========================================================

IMG_URL="https://yoshi10321.github.io/e-inkdashboard/dash.png"
BAT_URL_BASE="https://yoshi10321.github.io/e-inkdashboard/bat"
DATA_URL="https://yoshi10321.github.io/e-inkdashboard/data.json"
BLACK_URL="https://yoshi10321.github.io/e-inkdashboard/black.png"

# 描画前に画面を一度黒く塗ってから白に戻すか（残像消し）
#   1 : 消す。更新のたびに一瞬黒い画面が入るが、前の絵が完全に抜ける。
#   0 : 消さない。更新は静かだが、濃い図形の消え残りが溜まることがある。
FLASH_BEFORE_DRAW=1

# 更新間隔（秒）。3600 = 1時間
INTERVAL=3600

# 動作モード
#   awake   : サスペンドしない。動作確認用。電池はどんどん減る。
#   suspend : 更新の合間はサスペンドする。常用はこちら。
MODE="suspend"

# Kindle の UI（ホーム画面・ステータスバー）を描画前に止めるか
#   1 : 止める。時計やステータスバーが描かれなくなる。
#   0 : 止めない。画面の端に Kindle 標準のステータスバーが残る。
STOP_FRAMEWORK=1

# バッテリー残量のアイコンを重ねて表示するか
SHOW_BATTERY=1

# 毎日 0時ちょうどにも更新するか
#   1 : INTERVAL とは別に、日付が変わった瞬間にも起きて更新する。
#       画面の日付が変わるのを待たずに済む。
#   0 : INTERVAL の間隔だけで動く。
UPDATE_AT_MIDNIGHT=1

# ====================================================================

WORKDIR=/mnt/us
IMG="$WORKDIR/dashboard.png"
BATIMG="$WORKDIR/dashboard_bat.png"
BLACKIMG="$WORKDIR/dashboard_black.png"
LOG="$WORKDIR/dashboard.log"
STOPFILE="$WORKDIR/documents/dashboard.stop"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# ログが肥大化しないよう、起動時に大きければ切り詰める
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 100000 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "===== 起動 (mode=$MODE interval=${INTERVAL}s UI停止=$STOP_FRAMEWORK) ====="

# スクリプトの標準出力・標準エラーはそのまま画面に描かれてしまい、
# eips の内部メッセージがダッシュボードの上に重なる。すべて捨てる。
# （log() は直接ファイルへ書くので、この後もログは残る）
exec >/dev/null 2>&1

# --- UI フレームワーク ----------------------------------------------
# ファームウェアによって init スクリプト方式と upstart 方式があるので両方試す。

FRAMEWORK_STOPPED=0

stop_framework() {
    [ "$STOP_FRAMEWORK" = "1" ] || return 0
    [ "$FRAMEWORK_STOPPED" = "1" ] && return 0
    if [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework stop
    else
        stop lab126_gui 2>/dev/null || initctl stop lab126_gui 2>/dev/null
    fi
    FRAMEWORK_STOPPED=1
    log "UI を停止した"
    sleep 3
}

start_framework() {
    [ "$FRAMEWORK_STOPPED" = "1" ] || return 0
    if [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework start
    else
        start lab126_gui 2>/dev/null || initctl start lab126_gui 2>/dev/null
    fi
    FRAMEWORK_STOPPED=0
    log "UI を再開した（ネットワーク作業のため）"
    # 起動しきるまで待つ。短すぎると lipc がまだ応答しない。
    sleep 15
}

# --- Wi-Fi ----------------------------------------------------------
# UI が動いている間にだけ呼ぶこと（lipc の com.lab126.cmd が必要）

wifi_on() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
}

wifi_off() {
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
    log "Wi-Fi を切った"
}

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

# --- バッテリー残量 --------------------------------------------------

battery_level() {
    # sysfs が最も確実（UI にも lipc にも依存しない）
    for f in /sys/class/power_supply/*/capacity; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null | tr -dc '0-9')
        [ -n "$v" ] && { echo "$v"; return; }
    done
    v=$(gasgauge-info -s 2>/dev/null | tr -dc '0-9')
    [ -n "$v" ] && { echo "$v"; return; }
    v=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null | tr -dc '0-9')
    [ -n "$v" ] && { echo "$v"; return; }
    echo ""
}

# 用意してあるアイコンに合わせて 5% 刻みに丸める
round_to_5() {
    [ -z "$1" ] && { echo ""; return; }
    echo $(( ($1 + 2) / 5 * 5 ))
}

# --- ダウンロード（Wi-Fi がある間に済ませる） ------------------------

# 共通のダウンロード処理。PNG として妥当かどうかも確認する。
download_png() {
    url=$1
    dest=$2
    if wget -q --no-check-certificate -O "$dest.tmp" "$url" 2>>"$LOG"; then
        if [ -s "$dest.tmp" ] && head -c 4 "$dest.tmp" | grep -q "PNG"; then
            # eips が読めるのは 8bit グレースケール(色種別0)の PNG だけ。
            # 4bit などで来ると、描画が失敗して画面が真っ白になる。
            # PNG の IHDR は 24 バイト目が bit深度、25 バイト目が色種別。
            ihdr=$(od -An -tu1 -j24 -N2 "$dest.tmp" 2>/dev/null | tr -s ' ')
            case "$ihdr" in
                *" 8 0"*|*" 8 4"*) : ;;
                "") : ;;   # od が無い端末では確認を飛ばす
                *) log "警告: PNG の形式が eips 向きでない (bit深度/色種別:$ihdr) $url" ;;
            esac
            mv "$dest.tmp" "$dest"
            return 0
        fi
        log "取得したファイルが PNG ではない: $url"
    else
        log "wget 失敗: $url"
    fi
    rm -f "$dest.tmp"
    return 1
}

# 公開されている画像が「今日のぶん」になるまで待つ。
#
# 0時ちょうどに起きても、画像を作る GitHub Actions 側はまだ前日ぶんを
# 出していることがある。data.json には作った時刻（日本時間）が入っているので、
# それが今日の日付になるまで少しだけ待つ。
#
# 待っても変わらなければ、前日ぶんの画像でそのまま進む。
# 次の正時にはどのみち新しくなる。
wait_for_todays_image() {
    today=$(date '+%Y-%m-%d')
    i=0
    while [ $i -lt 6 ]; do
        gen=$(wget -q --no-check-certificate -O - "${DATA_URL}?t=$(date +%s)" 2>/dev/null |
              sed -n 's/.*"generated":"\([^"]*\)".*/\1/p')
        case "$gen" in
            "$today"*)
                [ $i -gt 0 ] && log "今日ぶんの画像ができた（${i}回待った）"
                return 0 ;;
        esac
        i=$((i + 1))
        log "画像がまだ前日ぶん (generated=${gen:-不明})。60秒待つ"
        sleep 60
    done
    log "今日ぶんの画像を待ちきれなかった。前日ぶんのまま進む"
    return 1
}

# 公開されている画像がいつ作られたものか記録する。
#
# 画像を作っているのは GitHub Actions だが、GitHub のスケジュール実行は
# ベストエフォートで、間引かれると何時間も古いままになる。
# 端末側からは見分けがつかないので、ログに残して気づけるようにする。
log_image_age() {
    gen=$(wget -q --no-check-certificate -O - "${DATA_URL}?t=$(date +%s)" 2>/dev/null |
          sed -n 's/.*"generated":"\([^"]*\)".*/\1/p')
    if [ -z "$gen" ]; then
        log "画像の生成時刻を取得できなかった"
        return
    fi
    today=$(date '+%Y-%m-%d')
    case "$gen" in
        "$today"*) log "画像の生成時刻 $gen（本日ぶん）" ;;
        *)         log "警告: 画像が古い。生成時刻 $gen / 本日は $today" ;;
    esac
}

fetch_all() {
    log_image_age

    # 本体
    if download_png "${IMG_URL}?t=$(date +%s)" "$IMG"; then
        log "本体画像 取得成功 ($(wc -c < "$IMG") bytes)"
    fi

    # バッテリーアイコン
    [ "$SHOW_BATTERY" = "1" ] || return 0
    bat=$(battery_level)
    if [ -z "$bat" ]; then
        log "電池残量を取得できず"
        return 0
    fi
    lv=$(round_to_5 "$bat")
    [ "$lv" -gt 100 ] 2>/dev/null && lv=100
    [ "$lv" -lt 0 ] 2>/dev/null && lv=0
    log "電池 ${bat}% → アイコン ${lv}%"

    if download_png "$BAT_URL_BASE/${lv}.png" "$BATIMG"; then
        log "アイコン 取得成功 ($(wc -c < "$BATIMG") bytes)"
    fi

    # 残像消し用の黒画像。中身は変わらないので一度取れば十分。
    if [ "$FLASH_BEFORE_DRAW" = "1" ] && [ ! -f "$BLACKIMG" ]; then
        if download_png "$BLACK_URL" "$BLACKIMG"; then
            log "残像消し用の黒画像 取得成功"
        fi
    fi
}

# --- 画面描画（UI を止めた後に呼ぶ） ---------------------------------

show_image() {
    if [ ! -f "$IMG" ]; then
        log "表示する画像がない（描画をスキップ）"
        return 1
    fi
    # 画面を一度黒く塗ってから白に戻す。
    #
    # E-ink の部分更新は前の絵を押し出す力が弱く、濃い図形が灰色の影として
    # 残る。Kindle 自身の UI を 1周ごとに起動し直している都合で、その間に
    # 描かれたものが残像になりやすい。
    # 黒 → 白 を一度通すと、どの画素も必ず両端まで振られるので影が消える。
    if [ "$FLASH_BEFORE_DRAW" = "1" ] && [ -f "$BLACKIMG" ]; then
        eips -g "$BLACKIMG"
        sleep 1
        log "黒→白で残像を消した"
    fi
    eips -c          # 白に戻す
    sleep 1

    # -f を付けると全画面を一度反転させてから描き直す（フル更新）。
    # これをしないと部分更新の波形が使われ、広い黒がきちんと沈まず、
    # 絵全体が眠く（ガビガビに）見える。-f を解さないファームもあるので、
    # 通る書き方を上から順に試して、最初に成功したものを使う。
    if eips -f -g "$IMG" 2>/dev/null; then
        log "本体画像を描画した（フル更新 -f -g）"
    elif eips -g "$IMG" 2>/dev/null && eips -f 2>/dev/null; then
        log "本体画像を描画した（描画後にフル更新 -f）"
    elif eips -g "$IMG"; then
        log "本体画像を描画した（通常更新）"
    else
        # ここまで来たら画像そのものが読めていない。原因を残す。
        log "描画に失敗した。eips の使い方:"
        eips -h >>"$LOG" 2>&1 || eips >>"$LOG" 2>&1
        return 1
    fi

    if [ "$SHOW_BATTERY" = "1" ] && [ -f "$BATIMG" ]; then
        # eips は画像を左上 (0,0) に等倍で描く。
        # dash.png は反時計回りに回してあるので、左上＝横向き設置時の画面上部。
        # こちらは白黒だけなので部分更新のままでよい。
        eips -g "$BATIMG"
        log "バッテリーアイコンを描画した"
    fi
    return 0
}

# --- サスペンド -----------------------------------------------------

suspend_for() {
    secs=$1
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
    return 0
}

# 指定の時刻まで待つ。
#
# RTC のアラームより先に、USB の抜き差しや電源ボタンで目が覚めることがある。
# そのまま次の周回に入ると、更新間隔を無視して通信と描画を繰り返してしまい、
# 電池をどんどん使う。目標時刻まで残っていれば、もう一度サスペンドし直す。
wait_until() {
    target=$1
    quick=0          # すぐ目が覚めた回数

    while true; do
        remain=$(( target - $(date +%s) ))
        [ "$remain" -le 0 ] && return 0

        # 停止ファイルが置かれていたら、待っている途中でも終わる
        [ -f "$STOPFILE" ] && return 0

        # 残りがごく僅かなら、サスペンドし直すより起きていた方が早い
        if [ "$remain" -lt 60 ] || [ "$MODE" != "suspend" ]; then
            sleep "$remain"
            return 0
        fi

        before=$(date +%s)
        suspend_for "$remain"
        slept=$(( $(date +%s) - before ))

        remain=$(( target - $(date +%s) ))
        [ "$remain" -le 0 ] && return 0

        # USB をつないでいると、こちらの指定より先に何度も起こされる。
        # そのたびにログを書くと溢れるので、短時間で起こされた回数だけ数える。
        if [ "$slept" -lt 120 ]; then
            quick=$(( quick + 1 ))
            if [ "$quick" -ge 5 ]; then
                log "何度もすぐ起こされる（USB 接続中など）。以後は起きたまま待つ"
                sleep "$remain"
                return 0
            fi
        else
            quick=0
            log "予定より早く目が覚めた（残り ${remain}秒）。もう一度寝る"
        fi
    done
}

# --- 後始末 ---------------------------------------------------------

cleanup() {
    log "===== 終了 ====="
    start_framework
    exit 0
}
trap cleanup INT TERM

# --- メインループ ---------------------------------------------------

while true; do
    if [ -f "$STOPFILE" ]; then
        log "停止ファイルを検出した"
        rm -f "$STOPFILE"
        cleanup
    fi

    # 次に更新する時刻を先に決めておく。
    # 通信や描画にかかった時間ぶん間隔がずれていくのを防ぐ。
    NOW=$(date +%s)
    NEXT=$(( NOW + INTERVAL ))

    # 今日の 0時からの経過秒数。
    # date の出力は 08 のように 0 で始まるので、八進数と解釈されないよう剥がす。
    SECS_TODAY=$(( $(date '+%H' | sed 's/^0*//;s/^$/0/') * 3600 \
                 + $(date '+%M' | sed 's/^0*//;s/^$/0/') * 60 \
                 + $(date '+%S' | sed 's/^0*//;s/^$/0/') ))

    # 次の 0時が INTERVAL より先に来るなら、そちらを優先する
    if [ "$UPDATE_AT_MIDNIGHT" = "1" ]; then
        midnight=$(( NOW + 86400 - SECS_TODAY ))
        if [ "$midnight" -lt "$NEXT" ]; then
            NEXT=$midnight
            log "次は 0時に更新する（$(( (NEXT - NOW) / 60 ))分後）"
        fi
    fi

    # 1. ネットワーク作業は UI が動いている状態で行う
    start_framework
    wifi_on
    if wait_online; then
        # 0時を回った直後に起きたときは、画像が今日ぶんになるのを少し待つ
        if [ "$UPDATE_AT_MIDNIGHT" = "1" ] && [ "$SECS_TODAY" -lt 600 ]; then
            wait_for_todays_image
        fi
        fetch_all
    else
        log "オフラインのため前回の画像を表示する"
    fi

    # 2. Wi-Fi を切る（UI が動いているうちに）
    wifi_off

    # 3. UI を止めてから描画する（ステータスバーに上書きされないように）
    stop_framework
    show_image

    # 4. 次の更新時刻まで待つ
    wait_until "$NEXT"
done
