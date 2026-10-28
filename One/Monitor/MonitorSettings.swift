import SwiftUI

struct MonitorSettings: View {
    let monitor: MonitorModel

    var body: some View {
        Form {
            // メニューバーと右クリックのメニューで、別々に選ぶ。メニューバーは狭いので少しだけ出し、
            // メニューには全部出す、ができるように。
            Section {
                item(.network, in: .menuBar, "ネットワークの速度", "Wi-Fi と有線を合わせた受信（↓）と送信（↑）。VPN と Mac の中だけの通信は数えない。")
                item(.cpu, in: .menuBar, "CPU 使用率", "全部のコアを合わせた忙しさ。")
                item(.memory, in: .menuBar, "メモリ", "アクティビティモニタの「使用済みメモリ」に合わせた数え方の割合。")
                item(.disk, in: .menuBar, "ディスクの空き", "起動ディスクの空き。macOS が空けられる分（一時ファイルなど）も含める。")
                item(.claude, in: .menuBar, "Claude Code の使用量", "5時間の枠と週の枠を使った割合（「Claude 3% 週 14%」）。claude コマンドに聞く。")
                item(.codex, in: .menuBar, "Codex の使用量", "5時間の枠と週の枠を使った割合（「Codex 0% 週 46%」）。codex コマンドに聞く。")
            } header: {
                Text("メニューバーに出すもの（1つでも出すと、⌘ の代わりに数字が出る）")
            } footer: {
                Text("⌘ にポインタを載せると、ここで選んだものの細かい数（メモリの GB など）が出る。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                item(.network, in: .menu, "ネットワークの速度")
                item(.cpu, in: .menu, "CPU 使用率")
                item(.memory, in: .menu, "メモリ（使っている量 / 積んでいる量）")
                item(.disk, in: .menu, "ディスクの空き")
                item(.claude, in: .menu, "Claude Code の使用量（枠が戻る時刻も）")
                item(.codex, in: .menu, "Codex の使用量（枠が戻る時刻も）")
            } header: {
                Text("⌘ の右クリックのメニューに出すもの")
            } footer: {
                Text("1秒ごとに測る。Claude Code と Codex の使用量は5分ごとと、メニューを開いたときに聞く。どこにも出さないものは測らず、ディスプレイが眠っている間も測らない。温度や GPU は、Apple が公開していない仕組みが要るので出さない。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 出す・出さないのスイッチ。値は `MonitorModel` が場所ごとの並びとして持っているので、
    /// 読み書きの手続きを自分で書いて Binding を作る。
    private func item(_ item: Monitor.Item, in place: MonitorModel.Place, _ title: String, _ note: String? = nil) -> some View {
        Toggle(isOn: Binding(get: { monitor.isShown(item, in: place) }, set: { monitor.setShown(item, in: place, $0) })) {
            Text(title)
            if let note {
                Text(note)
            }
        }
    }
}
