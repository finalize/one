import SwiftUI

/// 設定の窓の各タブの形をそろえる。窓とタブそのものは `SettingsWindow` が AppKit で組み、
/// 各タブの中身はそれぞれの機能のフォルダにある（`GeneralSettings`・`InputSettings`・
/// `WindowSettings`・`MirrorSettings`・`CalendarSettings`・`MonitorSettings`）。
///
/// 前は SwiftUI の `Settings` シーンの中に `TabView` を置いていた。アイコンの左右の
/// クリックを見分けるためにメニューバーの部分を AppKit にしたところ、`Settings` シーンを
/// 開く手段が無くなった。開く `openSettings` は SwiftUI の画面の中からしか呼べず、
/// AppKit のメニューからは届かない。中身は SwiftUI のまま、入れ物だけを AppKit にしてある。
///
/// `@Bindable` は `@Observable` なオブジェクトから `$model.isSwapped` の形で
/// 双方向の結び付き（Binding）を作れるようにする印。Toggle のように
/// 「読むだけでなく書き換えもする」部品に渡すときに必要になる。
extension View {
    /// 設定の1ページの形にそろえる。
    ///
    /// `.grouped` は、システム設定と同じ「角の丸い箱に項目を並べる」見た目。幅は固定し、
    /// 高さは中身に任せる。窓はこの大きさに合わせて、タブを切り替えるたびに伸び縮みする。
    func settingsPage() -> some View {
        formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}
