import SwiftUI

struct WindowSettings: View {
    @Bindable var windows: WindowModel

    var body: some View {
        Form {
            Toggle(isOn: $windows.arrangesWindows) {
                Text("ショートカットで動かす")
                Text("⌃⌥← などで、手前のウィンドウを半分や 1/3 に並べる。キーは右クリックのメニューの「ウィンドウ」に出る。Rectangle と一緒に使うなら切る。メニューから選んで動かすのは、切っていてもできる。")
            }
            Toggle(isOn: $windows.snapsWindows) {
                Text("ドラッグで端に寄せて並べる")
                Text("macOS 自身の、端へ寄せて並べる機能（システム設定 > デスクトップと Dock）を使うなら切る。両方入っていると1回のドラッグに両方が反応する。")
            }
        }
    }
}
