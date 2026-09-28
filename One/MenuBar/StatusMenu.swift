import AppKit

/// ⌘ の右クリックのメニュー。
///
/// 開くたびに作り直す。許可や鏡の状態は、開いた時点のものを出したい。メニューには操作だけを置き、
/// 切り替えや選択は設定の窓（`SettingsWindow`）に集めた。上のほうにモニタの数字を出し、開いている間は
/// 1秒ごとに書き換える（`updateMonitorRows`）。
@MainActor
final class StatusMenu {
    private let model: AppModel
    private let windows: WindowModel
    private let mirror: MirrorModel
    private let monitor: MonitorModel
    private let settings: SettingsWindow

    /// ⌘ のアイコンの矩形と画面。鏡をこの真下に出す（`StatusItemController` が渡す）。
    var anchor: (() -> (frame: NSRect, screen: NSScreen)?)?

    /// モニタの数字の項目。開いている間だけ持つ。
    private var monitorItems: [NSMenuItem] = []

    init(model: AppModel, windows: WindowModel, mirror: MirrorModel, monitor: MonitorModel, settings: SettingsWindow) {
        self.model = model
        self.windows = windows
        self.mirror = mirror
        self.monitor = monitor
        self.settings = settings
    }

    func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if !model.isTrusted {
            let warning = NSMenuItem(title: "キー入力を見る許可がありません", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(ClosureMenuItem("アクセシビリティ設定を開く…") { [unowned self] in
                model.openAccessibilitySettings()
            })
            menu.addItem(.separator())
        }

        // モニタの数字。「モニタ」タブで選んでいるものだけ。押しても何もしない項目なので灰色にする。
        monitorItems = monitor.detailLines(for: .menu).map { text in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = Self.monitorTitle(text)
            item.isEnabled = false
            return item
        }
        if !monitorItems.isEmpty {
            monitorItems.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let windows = NSMenuItem(title: "ウィンドウ", action: nil, keyEquivalent: "")
        windows.submenu = windowMenu()
        menu.addItem(windows)
        menu.addItem(ClosureMenuItem(mirror.isVisible ? "鏡を隠す" : "鏡を出す") { [unowned self] in
            // 鏡はアイコンの真下に出す。
            guard let place = anchor?() else { return }
            mirror.toggle(midX: place.frame.midX, on: place.screen)
        })
        menu.addItem(.separator())

        let settingsItem = ClosureMenuItem("設定…") { [unowned self] in settings.show() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "One を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// 開いているメニューのモニタの数字を書き換える。閉じていれば何もしない。
    ///
    /// 行の数が合わないとき（開いている間に「モニタ」タブで項目を変えた）も何もしない。
    /// 次に開いたときに作り直される。
    func updateMonitorRows(_ lines: [String]) {
        guard monitorItems.count == lines.count else { return }
        for (item, text) in zip(monitorItems, lines) {
            item.attributedTitle = Self.monitorTitle(text)
        }
    }

    /// メニューが閉じた。モニタの項目を手放す。
    func didClose() {
        monitorItems = []
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in Self.windowGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = ClosureMenuItem(action.title) { [unowned self] in windows.arrange(action) }
                // ショートカットを登録しているときだけ、右側にキーを出す。
                // 切っているのに出すと、押せば効くように見えてしまう。
                if windows.arrangesWindows {
                    item.keyEquivalent = String(action.shortcut.key.character)
                    item.keyEquivalentModifierMask = action.shortcut.modifierFlags
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    /// モニタの項目の字。数字の幅がそろう字にして、1秒ごとに書き換わっても文字が左右に揺れないように。
    private static func monitorTitle(_ text: String) -> NSAttributedString {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)])
    }

    /// ウィンドウのメニューに並べる順と、区切り線の入れ方。
    private static let windowGroups: [[WindowAction]] = [
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds],
        [.maximize, .maximizeHeight, .center, .larger, .smaller, .restore],
        [.previousDisplay, .nextDisplay],
    ]
}
