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

# Kindle の UI（ホーム画面・ステータスバー）を止めるか
#   1 : 止める。時計やステータスバーが描かれなくなる。
#   0 : 止めない。画面の端に Kindle 標準のステータスバーが残る。
STOP_FRAMEWORK=1

# UI を起動せずに接続できなかったとき、従来どおり UI を起こしてやり直すか
#
# 2026-10-10 の調査で、UI を止めたままでも
#   lipc-set-prop com.lab126.cmd wirelessEnable 1
# で 6 秒で接続でき、wget も通ることを実機で確認した（wifi-probe.log）。
# cmd は PID 2047 で lxinit や Xorg より先に起動する独立したデーモンであり、
# lab126_gui を止めても死なない。UI は Wi-Fi に必要ではなかった。
#
# ただし調査はサスペンドを挟まずに行ったので、**復帰直後も同じとは未確認**。
# 繋がらなければ UI を起こす経路に落ちる。落ちた回数はログに残すので、
# 一度も落ちないことが確認できたら 0 にしてよい。
UI_FALLBACK=1

# バッテリー残量のアイコンを重ねて表示するか
SHOW_BATTERY=1

# 毎日 0時ちょうどにも更新するか
#   1 : INTERVAL とは別に、日付が変わった瞬間にも起きて更新する。
#       画面の日付が変わるのを待たずに済む。
#   0 : INTERVAL の間隔だけで動く。
UPDATE_AT_MIDNIGHT=1

# 0時の更新を何秒ずらすか。
#
# 画像は 23:50 の実行で「翌日ぶん」として作られ、0 時前には出来上がっている。
# ビルドの完了を待つ必要がないので、0 時直後で足りる。
MIDNIGHT_OFFSET=120

# 夜間は更新を止める（電池の節約）
#
# この時間帯は通信も描画もせず、寝たまま過ごす。
# E-ink なので電源を使わなくても前の表示は残る。
# 1 時間あたり 30 秒ほど起きているぶんが、その回数だけ減る。
#
# 両方 0 なら無効。0〜23 の整数で指定する。
# 例: QUIET_START=1 / QUIET_END=6 なら 1時台〜5時台は動かない。
#
# 夜間の指定は 0時の更新より優先される。日付を 0時に切り替えたいなら
# 0時台を含めないこと（23 や 0 から始めると、朝まで前日のままになる）。
QUIET_START=0
QUIET_END=0

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

# スクリプトを起動してから最初の描画かどうか。
# 再起動後はホーム画面が長く出ていて焼き付いていることがあるため、
# 最初の 1 回だけ消し込みを強くする。
FIRST_DRAW=1

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

# UI を起こす。
#
# 通常の周回では**呼ばない**。呼ぶのは Wi-Fi が繋がらなかったときだけ。
# UI を起こすと Kindle がホーム画面を描き、同じ図形が同じ場所に重なって
# E-ink に焼き付く（10/5 と 10/10 に幅 51〜52px の帯を実測）。
start_framework() {
    [ "$FRAMEWORK_STOPPED" = "1" ] || return 0
    if [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework start
    else
        start lab126_gui 2>/dev/null || initctl start lab126_gui 2>/dev/null
    fi
    FRAMEWORK_STOPPED=0
    log "UI を起こした（接続できなかったため。画面に焼き付きが残る）"
    # 起動しきるまで待つ。短すぎると lipc がまだ応答しない。
    sleep 15
}

# UI を起こした回数。0 のままなら UI_FALLBACK を切ってよい。
UI_FALLBACK_COUNT=0

# --- 不意のサスペンド対策 ------------------------------------------
#
# Kindle 本体の電源管理は、こちらの作業中かどうかに関係なく端末を寝かせる。
# 実際 2026-10-06 00:00 の周回では、Wi-Fi の接続待ちの最中に寝てしまい、
# 起床アラームが無かったせいで 5時間15分そのまま戻ってこなかった。
#
# 作業中は常に数分後のアラームを仕掛けておく。寝ても必ず戻ってくる。
# 起きたまま時間切れになった場合は何も起こらないので、掛け捨てでよい。
WATCHDOG=240

arm_watchdog() {
    for rtc in /sys/class/rtc/rtc1/wakealarm /sys/class/rtc/rtc0/wakealarm; do
        [ -w "$rtc" ] || continue
        echo 0 > "$rtc" 2>/dev/null
        echo "+$WATCHDOG" > "$rtc" 2>/dev/null && return 0
    done
    return 1
}

# --- Wi-Fi ----------------------------------------------------------

wifi_on() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
}

wifi_off() {
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
    log "Wi-Fi を切った"
}

# cmState が CONNECTED になっただけでは通信できない。
#
# 10/10 の調査で、CONNECTED かつ IP 払い出し済みになった**同じ秒**に wget を
# 撃ったところ即座に失敗した。wget の待ち時間は 20 秒に設定していたのに
# 待たずに戻ったので、タイムアウトではなく名前解決の失敗である。
# 1 秒後に撃ち直したら 8594 bytes 取れた。
#
# そのため IP が付くまで待ち、さらにこの秒数だけ置く。
NET_SETTLE=3

wait_online() {
    i=0
    while [ $i -lt 30 ]; do
        state=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
        # IP が付いていなければ、まだ DHCP が終わっていない
        ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
        if [ "$state" = "CONNECTED" ] && [ -n "$ip" ]; then
            log "Wi-Fi 接続 OK（$(( i * 2 ))秒 / IP あり）"
            sleep "$NET_SETTLE"
            return 0
        fi
        # 接続待ちの最中に寝かされても戻ってこられるようにする
        arm_watchdog
        sleep 2
        i=$((i + 1))
    done
    if [ -n "$ip" ]; then has_ip=あり; else has_ip=なし; fi
    log "Wi-Fi 接続タイムアウト（状態: ${state:-不明} / IP: $has_ip）"
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
    # 繋がった直後は一度こけることがあるので、一度だけ撃ち直す
    if ! wget -q --no-check-certificate -O "$dest.tmp" "$url" 2>>"$LOG"; then
        log "wget 1回目が失敗した。3秒後に撃ち直す: $url"
        sleep 3
        wget -q --no-check-certificate -O "$dest.tmp" "$url" 2>>"$LOG"
    fi
    if [ -s "$dest.tmp" ]; then
        if head -c 4 "$dest.tmp" | grep -q "PNG"; then
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

# 公開されている画像が「いつのぶん」か記録する。
#
# for_date は、その画像がどの日付として作られたかを表す。
# 日付が変わる少し前に「翌日ぶん」として作ることがあるため、
# 生成時刻ではなくこちらを見る。
log_image_age() {
    IMAGE_IS_TODAY=0
    body=$(wget -q --no-check-certificate -O - "${DATA_URL}?t=$(date +%s)" 2>/dev/null)
    if [ -z "$body" ]; then
        # 繋がった直後は一度こけることがある
        sleep 3
        body=$(wget -q --no-check-certificate -O - "${DATA_URL}?t=$(date +%s)" 2>/dev/null)
    fi
    gen=$(echo "$body" | sed -n 's/.*"for_date":"\([^"]*\)".*/\1/p')
    # 古い形式（for_date が無い）なら生成時刻で代用する
    [ -z "$gen" ] && gen=$(echo "$body" | sed -n 's/.*"generated":"\([^"]*\)".*/\1/p')

    if [ -z "$gen" ]; then
        log "画像の日付を取得できなかった"
        return
    fi
    today=$(date '+%Y-%m-%d')
    case "$gen" in
        "$today"*) IMAGE_IS_TODAY=1; log "画像は本日ぶん ($gen)" ;;
        *)         log "警告: 画像が本日ぶんでない ($gen / 本日は $today)" ;;
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
    #
    # ただし同じ絵が長時間出ていた場合（端末が再起動してホーム画面が
    # 何時間も表示されたときなど）は、1 回では抜けきらない。
    # スクリプトを起動した直後だけ、回数を増やして強く振る。
    if [ "$FLASH_BEFORE_DRAW" = "1" ] && [ -f "$BLACKIMG" ]; then
        if [ "$FIRST_DRAW" = "1" ]; then
            n=0
            while [ $n -lt 3 ]; do
                eips -g "$BLACKIMG"
                sleep 1
                eips -c
                sleep 1
                n=$((n + 1))
            done
            log "起動直後のため、黒→白を3回通して残像を強く消した"
        else
            eips -g "$BLACKIMG"
            sleep 1
            log "黒→白で残像を消した"
        fi
    fi
    FIRST_DRAW=0
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

    # 使える RTC すべてにアラームを仕掛ける。
    #
    # 以前は rtc1 に仕掛かった時点で打ち切っていたが、
    # 2026-10-08 22:30 の回でそのアラームが効かず、46分寝過ごした
    # （予定 23:29:37 に対して実際の起床は 00:16:01）。
    # 片方が効かなくても、もう片方で起きられるようにしておく。
    armed=""
    for rtc in /sys/class/rtc/rtc1/wakealarm /sys/class/rtc/rtc0/wakealarm; do
        [ -w "$rtc" ] || continue
        echo 0 > "$rtc" 2>/dev/null
        if echo "+$secs" > "$rtc" 2>/dev/null; then
            armed="$armed $rtc"
        fi
    done

    if [ -z "$armed" ]; then
        log "RTC が使えなかったので通常の sleep で待機"
        sleep "$secs"
        return 0
    fi

    log "サスペンド開始 (${secs}秒後に起床予定,${armed})"
    before=$(date +%s)
    echo mem > /sys/power/state 2>>"$LOG"

    # 起きた瞬間にアラームは消費されている。次を仕掛けるまでの間に
    # 端末が自分で寝ると、起こす者がいなくなる。
    # 実際 2026-10-08 と 10-09 の 2 回、この隙間で数時間止まった。
    # 何よりも先に仕掛け直す。
    arm_watchdog

    slept=$(( $(date +%s) - before ))

    # 予定より 2 分以上長く寝ていたら、アラームが効かなかったということ。
    # 黙って遅れると画面が何時間も古いままになるので、必ず記録する。
    if [ "$slept" -gt $(( secs + 120 )) ]; then
        log "警告: 起床が $(( slept - secs ))秒 遅れた（予定 ${secs}秒 / 実際 ${slept}秒）"
    else
        log "起床"
    fi
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

        # 残りがごく僅かなら、サスペンドし直すより起きていた方が早い。
        # ただし起きたまま待つ間も端末は勝手に寝るので、保険を掛けておく。
        if [ "$remain" -lt 60 ] || [ "$MODE" != "suspend" ]; then
            arm_watchdog
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
                arm_watchdog
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

# UI は起動時に一度だけ止め、以降二度と起こさない。
#
# このスクリプトは本として開いて起動するので、この時点では必ず UI が
# 動いていてホーム画面が描かれている。ここで止めてしまえば、以降
# ホーム画面が描かれる機会は無くなり、帯の進行も止まる。
# 起動時までに溜まった焼き付きは、最初の描画で黒→白を 3 回通して抜く。
arm_watchdog
stop_framework

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

    # 夜間の時間帯なら、何もせずに明けるまで寝る。
    # UI を起こさないので画面はそのまま残る（描き直す必要がない）。
    if [ "$QUIET_START" != "$QUIET_END" ]; then
        hour=$(date '+%H' | sed 's/^0*//;s/^$/0/')
        quiet=0
        if [ "$QUIET_START" -lt "$QUIET_END" ]; then
            # 例: 1〜6（日をまたがない）
            [ "$hour" -ge "$QUIET_START" ] && [ "$hour" -lt "$QUIET_END" ] && quiet=1
        else
            # 例: 23〜6（日をまたぐ）
            if [ "$hour" -ge "$QUIET_START" ] || [ "$hour" -lt "$QUIET_END" ]; then
                quiet=1
            fi
        fi
        if [ "$quiet" = "1" ]; then
            end_secs=$(( QUIET_END * 3600 ))
            if [ "$SECS_TODAY" -lt "$end_secs" ]; then
                NEXT=$(( NOW + end_secs - SECS_TODAY ))
            else
                NEXT=$(( NOW + 86400 - SECS_TODAY + end_secs ))
            fi
            log "夜間のため更新しない。${QUIET_END}時まで寝る（$(( (NEXT - NOW) / 60 ))分）"
            wait_until "$NEXT"
            continue
        fi
    fi

    # 23:40〜24:00 には取りに行かない。
    #
    # この時間帯には、すでに翌日ぶんの画像が公開されていることがある。
    # うっかり取ると、日付が変わる前に翌日の画面が出てしまう。
    # 23:30 の実行が遅れた場合も見込んで、23:40 から窓を取る。
    # 周回がこの窓に当たる場合は手前（23:39）にずらす。
    if [ "$UPDATE_AT_MIDNIGHT" = "1" ]; then
        # 23:40 = 85200 秒、23:39 = 85140 秒
        next_tod=$(( (SECS_TODAY + INTERVAL) % 86400 ))
        if [ "$next_tod" -ge 85200 ]; then
            NEXT=$(( NOW + 85140 - SECS_TODAY ))
            log "次の周回が 23:40〜24:00 に当たるので 23:39 にずらす"
        fi
    fi

    # 次の 0時が INTERVAL より先に来るなら、そちらを優先する
    if [ "$UPDATE_AT_MIDNIGHT" = "1" ]; then
        if [ "$SECS_TODAY" -lt "$MIDNIGHT_OFFSET" ]; then
            # 今日のぶんがまだ来ていない（0時を回った直後）
            midnight=$(( NOW + MIDNIGHT_OFFSET - SECS_TODAY ))
        else
            midnight=$(( NOW + 86400 - SECS_TODAY + MIDNIGHT_OFFSET ))
        fi
        if [ "$midnight" -lt "$NEXT" ]; then
            NEXT=$midnight
            log "次は 0時すぎに更新する（$(( (NEXT - NOW) / 60 ))分後）"
        fi
    fi

    # 1. 通信する。UI は起こさない。
    #
    #    以前は 1 周ごとに UI を起動していた。Wi-Fi の制御に UI が必要だと
    #    思っていたからだが、10/10 の実機調査でそれは誤りだと分かった。
    #    UI を止めたままでも wirelessEnable 1 で 6 秒で繋がる。
    #
    #    通信も描画も、途中で寝かされる可能性がある。先にアラームを仕掛ける。
    arm_watchdog
    wifi_on
    ONLINE=0
    if wait_online; then
        ONLINE=1
    elif [ "$UI_FALLBACK" = "1" ]; then
        # 想定外。サスペンド復帰直後だと駄目なのかもしれない。
        # 画面が止まるほうが困るので、ここだけは UI を起こして取りに行く。
        log "警告: UI なしで接続できなかった"
        start_framework
        arm_watchdog
        wifi_on
        if wait_online; then
            ONLINE=1
            UI_FALLBACK_COUNT=$(( UI_FALLBACK_COUNT + 1 ))
            log "UI を起こして接続できた（起動後 ${UI_FALLBACK_COUNT}回目）"
        fi
    fi

    if [ "$ONLINE" = "1" ]; then
        fetch_all
    else
        log "オフラインのため前回の画像を表示する"
    fi

    # 2. Wi-Fi を切る
    wifi_off

    # 3. 描画する。
    #    UI は通常もう止まっている。起こしてしまった場合だけ止め直す。
    stop_framework
    arm_watchdog
    show_image

    # 4. 0時台に前日ぶんの画像しか無かった場合は、早めに出直す。
    #
    #    画像を作る GitHub 側のスケジュールは当てにならず、0時に間に合わない
    #    ことがある。かといってここで待つと、その間 Wi-Fi が入ったまま
    #    電池を舐めるだけで画面も変わらない。
    #    先に描いてしまってから、短い間隔で出直すほうがよい。
    if [ "$UPDATE_AT_MIDNIGHT" = "1" ] \
       && [ "$SECS_TODAY" -lt 1800 ] \
       && [ "${IMAGE_IS_TODAY:-1}" = "0" ]; then
        NEXT=$(( $(date +%s) + 600 ))
        log "画像がまだ前日ぶん。10分後に出直す"
    fi

    # 5. 次の更新時刻まで待つ
    wait_until "$NEXT"
done
