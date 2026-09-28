#!/bin/sh
# 画面もキーボードも使わずに確かめられる部分を試す。
#
# 1. 単独押しの判定（CommandKeyWatcher）を、合成した NSEvent で。
#    実際のキーボードを叩くテストは書けない（アクセシビリティ許可が要るし、
#    CI でも走らない）。判定を CommandKeyWatcher.process() に切り出してあるので、
#    イベントを自分で作って流し込めば、キーボード無しで全部試せる。
# 2. ウィンドウの行き先の計算（WindowLayout / WindowHistory）を、作った画面の大きさで。
#    計算は画面の状態を引数で受け取るので、実際の画面が何枚あっても関係なく試せる。
# 3. ドラッグでのスナップ（SnapLayout）を、作った画面とカーソルの位置で。
#    1回のドラッグの解釈（SnapTracker）も、押す・動かす・離すを並べて渡せば試せる。
# 4. 鏡のノッチの位置・窓の置き場所・画質（NotchGeometry / PanelPlacement / Quality）。
#    どれも NSScreen やカメラから取り出した数字だけを受け取るので、ノッチもカメラも要らない。
# 5. カレンダーの月の表と、予定をどの日に出すか（CalendarGrid）。
#    暦と日付だけを受け取るので、カレンダー.app の予定も、この Mac の週の始まりや地域も要らない。
# 6. メニューバーに出す数字の計算と書き方（Monitor）。
#    OS から読んだ数を引数で受け取るので、実際の CPU やネットワークは要らない。
#
# それぞれ @main を持つ別の実行ファイルにする。1つにまとめると入口がいくつもできてしまう。
set -e
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

swiftc -o "$out/watcher" One/CommandKeyWatcher.swift One/Log.swift Tests/WatcherTests.swift
swiftc -o "$out/window" One/WindowLayout.swift One/WindowHistory.swift Tests/WindowLayoutTests.swift
swiftc -o "$out/snap" One/WindowLayout.swift One/WindowHistory.swift One/SnapLayout.swift Tests/SnapLayoutTests.swift
swiftc -o "$out/mirror" One/NotchGeometry.swift One/PanelPlacement.swift One/Quality.swift Tests/MirrorTests.swift
swiftc -o "$out/calendar" One/CalendarGrid.swift Tests/CalendarGridTests.swift
swiftc -o "$out/monitor" One/Monitor.swift Tests/MonitorTests.swift

# どれかが落ちても、ほかの結果も見えるように全部走らせてから終える。
status=0
"$out/watcher" || status=1
echo
"$out/window" || status=1
echo
"$out/snap" || status=1
echo
"$out/mirror" || status=1
echo
"$out/calendar" || status=1
echo
"$out/monitor" || status=1
exit $status
