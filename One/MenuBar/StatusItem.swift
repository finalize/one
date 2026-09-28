import AppKit

/// メニューバーの ⌘ のアイコン。見た目と、クリックの振り分け。
///
/// 左クリックでカレンダー、右クリック（か control + クリック）でメニュー。よく使うほうを左に置いた。
/// 設定の窓の「カレンダー」タブで入れ替えられる。
///
/// ボタンの行き先（target と action）を持つので、`@objc` のメソッドが書ける NSObject の子にしてある。
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let input: InputModel
    private let monitor: MonitorModel
    private let calendar: CalendarController
    private let menu: StatusMenu
    private let statusItem: NSStatusItem

    init(model: AppModel, input: InputModel, monitor: MonitorModel, calendar: CalendarController, menu: StatusMenu) {
        self.model = model
        self.input = input
        self.monitor = monitor
        self.calendar = calendar
        self.menu = menu
        // 幅は中身に合わせる。「A / あ も出す」やモニタの数字を入れると、そのぶん広がる。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.setAccessibilityLabel("One")
            button.target = self
            button.action = #selector(clicked)
            // 既定では左クリックでしか呼ばれない。右クリックでメニューを出したいので両方で呼ぶ。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // カレンダーも鏡も、アイコンの真下に出す。カレンダーは、アイコンの上のクリックを
        // 外のクリックとみなさない（`CalendarController.ignoredArea`）。
        calendar.ignoredArea = { [unowned self] in place?.frame }
        menu.anchor = { [unowned self] in place }
        updateButton()
    }

    /// アイコンの矩形（画面の座標）と、それがある画面。
    var place: (frame: NSRect, screen: NSScreen)? {
        guard let window = statusItem.button?.window, let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.frame, screen)
    }

    // MARK: - 見た目

    /// アイコンの見た目を今の設定に合わせる。
    ///
    /// SwiftUI の画面なら `@Observable` の値の変化で勝手に描き直されるが、AppKit のボタンは
    /// そうならない。`withObservationTracking` は、中で読んだ値のどれかが変わったら onChange を
    /// 1回だけ呼ぶ。onChange は値が変わる直前に呼ばれるので、次の回に回して読み直し、
    /// ついでにまた見張り直す。
    private func updateButton() {
        guard let button = statusItem.button else { return }
        withObservationTracking {
            // モニタの数字（1秒ごとに変わる）も読むので、出しているとここが毎秒呼ばれる。
            let columns = Monitor.columns(monitor.lines)
            if columns.isEmpty {
                // SF Symbols の "command"。テンプレート画像なので、メニューバーの明暗に合わせて
                // macOS が白黒を反転する。アプリのアイコンの色はここには使えない。
                let image = NSImage(systemSymbolName: "command", accessibilityDescription: "One")
                image?.isTemplate = true
                button.image = image
                if input.showsMode {
                    button.title = input.menuBarLabel
                    button.imagePosition = .imageLeading
                } else {
                    button.title = ""
                    button.imagePosition = .imageOnly
                }
            } else {
                // 数字を2段に並べるには、⌘ もモードの字も数字も1枚の画像に描くしかない（`StatusImage`）。
                button.image = StatusImage.make(
                    mode: input.showsMode ? input.menuBarLabel : nil,
                    columns: columns,
                    height: NSStatusBar.system.thickness
                )
                button.title = ""
                button.imagePosition = .imageOnly
            }
            // アイコンに載せたときの説明（メニューバーに出ている数の細かい版）。
            let barDetails = monitor.detailLines(for: .menuBar)
            button.toolTip = barDetails.isEmpty ? nil : barDetails.joined(separator: "\n")
            // 開いている右クリックのメニューの数字も、ここで一緒に書き換える。
            menu.updateMonitorRows(monitor.detailLines(for: .menu))
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateButton() }
        }
    }

    // MARK: - クリック

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        // 既定は左でカレンダー、右でメニュー。入れ替えていれば逆。
        // `==` を Bool 同士に使うと「同じなら」。右クリックで、かつ左がカレンダーならメニュー、という具合。
        if isRightClick == model.leftClickShowsCalendar {
            calendar.hide()
            showMenu()
        } else if let place {
            calendar.toggle(below: place.frame, on: place.screen)
        }
    }

    /// `statusItem.menu` を入れたままにすると、左クリックでもメニューが開いてしまう。
    /// 出すときだけ入れて、クリックを演じてから外す。`performClick` はメニューが
    /// 閉じるまで戻ってこないので、この順で書ける。
    private func showMenu() {
        statusItem.menu = menu.make()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        menu.didClose()
    }
}
