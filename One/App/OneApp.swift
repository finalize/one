import AppKit

/// アプリの入口。
///
/// `@main` が付いた型の `main()` が起動時の起点になる。Go の `func main()` と同じ役割。
/// ここではアプリの本体（`NSApplication`）に部品をつなぐ係（`AppDelegate`）を渡して、
/// 動かし始めるだけ。
///
/// 前は SwiftUI の `App` と `MenuBarExtra` で組んでいた。メニューバーのアイコンを
/// 左クリックでカレンダー、右クリックでメニュー、と分けたくなり、AppKit の
/// `NSStatusItem` に移した。`MenuBarExtra` はどちらのクリックも同じメニューを開くだけで、
/// 見分ける手段が無い。
///
/// Dock にも ⌘Tab にも出てこないのは、Info.plist の `LSUIElement = YES`
/// （プロジェクト設定の `INFOPLIST_KEY_LSUIElement`）による。
@main
@MainActor
enum OneApp {
    /// `NSApplication.delegate` は弱参照なので、どこかで持っていないと即座に消える。
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
