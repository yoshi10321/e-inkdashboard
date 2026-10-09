#!/bin/sh
#
# Wi-Fi の制御方法を調べるためだけのスクリプト
# ------------------------------------------------------------------
# いま dashboard.sh は、1 周ごとに Kindle の UI（フレームワーク）を
# 起動し直している。Wi-Fi の制御に使っている
#   lipc-set-prop com.lab126.cmd wirelessEnable
# がフレームワークの一部で、止めていると使えないため。
#
# その副作用として、起動のたびにホーム画面が描かれ、同じ場所に
# 同じ濃い図形が 1 日 24 回焼き付いて、画面に帯が残っている。
#
# もし Wi-Fi を管理している wifid がフレームワークとは別に生きているなら、
# UI を二度と起動せずに済む。それを確かめる。
#
# 【使い方】
#   このファイルを Kindle の documents フォルダに置き、本として開く。
#   1 分ほどで終わる。結果は /mnt/us/wifi-probe.log に書かれる。
#   終わると UI は元に戻る（画面にホーム画面が出たら成功）。
#
# 【安全性】
#   設定は何も変えない。読み取りと、一時的な停止・再開だけ。
#   最後に必ずフレームワークを戻す。途中で失敗しても、
#   電源ボタン長押しで再起動すれば元通りになる。
# ------------------------------------------------------------------

OUT=/mnt/us/wifi-probe.log

say() {
    echo "$(date '+%H:%M:%S') $*" >> "$OUT"
}

run() {
    echo "--- $* ---" >> "$OUT"
    "$@" >> "$OUT" 2>&1
    echo "   (終了コード $?)" >> "$OUT"
}

# 画面に余計なものを描かせない
exec >/dev/null 2>&1

: > "$OUT"
say "===== 調査開始 ====="
say "ファームウェア: $(cat /etc/prettyversion.txt 2>/dev/null || echo 不明)"

# ------------------------------------------------------------------
say ""
say "【1】フレームワークが動いている状態での情報"
# ------------------------------------------------------------------

run lipc-probe -a com.lab126.wifid
run lipc-get-prop com.lab126.wifid cmState

# 今つながっている SSID を知りたい。プロパティ名は端末によって違うので
# それらしいものを片っ端から読む。
for p in currentEssid essid cmConnectedSSID profile scanList; do
    echo "--- lipc-get-prop com.lab126.wifid $p ---" >> "$OUT"
    lipc-get-prop com.lab126.wifid "$p" >> "$OUT" 2>&1
    echo "   (終了コード $?)" >> "$OUT"
done

run iwconfig wlan0
run ifconfig wlan0

say "動いているプロセス（wifi 関連）"
ps >> "$OUT" 2>&1

# ------------------------------------------------------------------
say ""
say "【2】フレームワークを止める"
# ------------------------------------------------------------------

if [ -x /etc/init.d/framework ]; then
    run /etc/init.d/framework stop
else
    run stop lab126_gui
fi
sleep 8

say "止めた直後の状態"
run lipc-get-prop com.lab126.wifid cmState
run lipc-probe -a com.lab126.wifid

say "wifid のプロセスが残っているか"
ps 2>/dev/null | grep -i wifid >> "$OUT" 2>&1
echo "   (grep の終了コード $?  0 なら残っている)" >> "$OUT"

say "cmd のプロセスが残っているか（これは消えているはず）"
ps 2>/dev/null | grep -i "lab126.*cmd" >> "$OUT" 2>&1
echo "   (grep の終了コード $?)" >> "$OUT"

# ------------------------------------------------------------------
say ""
say "【3】フレームワークを止めたまま Wi-Fi を切って、つなぎ直せるか"
# ------------------------------------------------------------------

say "まず従来の方法（フレームワーク依存。失敗するはず）"
run lipc-set-prop com.lab126.cmd wirelessEnable 0

say "wifid 経由で切る"
run lipc-set-prop com.lab126.wifid cmDisconnect 1
sleep 5
run lipc-get-prop com.lab126.wifid cmState

say "wifid 経由でつなぎ直す（SSID は現在の設定から拾えたもの）"
SSID=$(lipc-get-prop com.lab126.wifid currentEssid 2>/dev/null)
[ -z "$SSID" ] && SSID=$(lipc-get-prop com.lab126.wifid essid 2>/dev/null)
say "使う SSID: ${SSID:-（取得できず）}"
if [ -n "$SSID" ]; then
    run lipc-set-prop com.lab126.wifid cmConnect "$SSID"
else
    say "SSID が分からないので cmConnect は試さない"
fi

i=0
while [ $i -lt 20 ]; do
    st=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    say "  ${i}回目: cmState=${st:-取得できず}"
    [ "$st" = "CONNECTED" ] && break
    sleep 2
    i=$((i + 1))
done

say "実際に通信できるか試す"
if wget -q --no-check-certificate -O /tmp/probe.bin \
        "https://yoshi10321.github.io/e-inkdashboard/data.json?t=$(date +%s)"; then
    say "  通信できた（$(wc -c < /tmp/probe.bin) bytes）"
else
    say "  通信できなかった"
fi
rm -f /tmp/probe.bin

# ------------------------------------------------------------------
say ""
say "【4】後始末：フレームワークを戻す"
# ------------------------------------------------------------------

if [ -x /etc/init.d/framework ]; then
    run /etc/init.d/framework start
else
    run start lab126_gui
fi

say "===== 調査終了 ====="
say "この結果（/mnt/us/wifi-probe.log）を見せてください"
