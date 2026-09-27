import AppKit

/// 部品をつなぐ。メニューバーのアイコンと右クリックのメニュー、カレンダー・鏡・設定の窓。
///
/// アイコンは左クリックでカレンダー、右クリック（か control + クリック）でメニュー。
/// よく使うほうを左に置いた。設定の窓の「カレンダー」タブで入れ替えられる。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 起動が済んでから作る（下の applicationDidFinishLaunching）。`!` は「使うときには
    // 必ず入っている」という約束で、入っていなければそこで落ちる。
    private var model: AppModel!
    private var mirror: MirrorModel!
    private var calendarModel: CalendarModel!
    private var calendar: CalendarController!
    private var settings: SettingsWindow!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        mirror = MirrorModel()
        calendarModel = CalendarModel()
        calendar = CalendarController(model: calendarModel)
        settings = SettingsWindow(model: model, mirror: mirror, calendar: calendarModel)

        // 幅は中身に合わせる。「A / あ も出す」を入れると文字のぶん広がる。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.setAccessibilityLabel("One")
            button.target = self
            button.action = #selector(statusItemClicked)
            // 既定では左クリックでしか呼ばれない。右クリックでメニューを出したいので両方で呼ぶ。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        calendar.ignoredArea = { [weak self] in self?.buttonPlace?.frame }
        updateButton()
    }

    // MARK: - アイコン

    /// アイコンの見た目を今の設定に合わせる。
    ///
    /// SwiftUI の画面なら `@Observable` の値の変化で勝手に描き直されるが、AppKit のボタンは
    /// そうならない。`withObservationTracking` は、中で読んだ値のどれかが変わったら onChange を
    /// 1回だけ呼ぶ。onChange は値が変わる直前に呼ばれるので、次の回に回して読み直し、
    /// ついでにまた見張り直す。
    private func updateButton() {
        guard let button = statusItem.button else { return }
        withObservationTracking {
            // SF Symbols の "command"。テンプレート画像なので、メニューバーの明暗に合わせて
            // macOS が白黒を反転する。アプリのアイコンの色はここには使えない。
            let image = NSImage(systemSymbolName: "command", accessibilityDescription: "One")
            image?.isTemplate = true
            button.image = image
            if model.showsMode {
                button.title = model.menuBarLabel
                button.imagePosition = .imageLeading
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateButton() }
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        // 既定は左でカレンダー、右でメニュー。入れ替えていれば逆。
        // `==` を Bool 同士に使うと「同じなら」。右クリックで、かつ左がカレンダーならメニュー、という具合。
        if isRightClick == model.leftClickShowsCalendar {
            calendar.hide()
            showMenu()
        } else if let place = buttonPlace {
            calendar.toggle(below: place.frame, on: place.screen)
        }
    }

    /// アイコンの矩形（画面の座標）と、それがある画面。
    private var buttonPlace: (frame: NSRect, screen: NSScreen)? {
        guard let window = statusItem.button?.window, let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.frame, screen)
    }

    /// `statusItem.menu` を入れたままにすると、左クリックでもメニューが開いてしまう。
    /// 出すときだけ入れて、クリックを演じてから外す。`performClick` はメニューが
    /// 閉じるまで戻ってこないので、この順で書ける。
    private func showMenu() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - 右クリックのメニュー

    /// 開くたびに作り直す。許可や鏡の状態は、開いた時点のものを出したい。
    ///
    /// メニューには操作だけを置く。切り替えや選択は設定の窓（`SettingsWindow`）に集めた。
    private func makeMenu() -> NSMenu {
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

        let windows = NSMenuItem(title: "ウィンドウ", action: nil, keyEquivalent: "")
        windows.submenu = windowMenu()
        menu.addItem(windows)
        menu.addItem(ClosureMenuItem(mirror.isVisible ? "鏡を隠す" : "鏡を出す") { [unowned self] in
            // 鏡はアイコンの真下に出す。
            guard let place = buttonPlace else { return }
            mirror.toggle(midX: place.frame.midX, on: place.screen)
        })
        menu.addItem(.separator())

        let settingsItem = ClosureMenuItem("設定…") { [unowned self] in settings.show() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "One を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in Self.windowGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = ClosureMenuItem(action.title) { [unowned self] in model.arrange(action) }
                // ショートカットを登録しているときだけ、右側にキーを出す。
                // 切っているのに出すと、押せば効くように見えてしまう。
                if model.arrangesWindows {
                    item.keyEquivalent = String(action.shortcut.key.character)
                    item.keyEquivalentModifierMask = action.shortcut.modifierFlags
                }
                menu.addItem(item)
            }
        }
        return menu
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
