import AppKit

/// 押されたらクロージャを呼ぶメニューの項目。
///
/// `NSMenuItem` は押されたときの行き先を「誰の（target）どのメソッドか（action）」で持ち、
/// そのメソッドは `@objc` を付けられる NSObject の子にしか書けない。`MirrorModel` も
/// `AppDelegate` のメニューも、項目ごとにメソッドを書くより、押されたときの処理を
/// その場に書けるほうが読みやすい。項目自身を行き先にして、渡されたクロージャを呼ぶ。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        // target は弱参照だが、項目はメニューが持っているので消えない。
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() { handler() }
}
