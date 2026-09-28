import AppKit
import SwiftUI

/// カレンダーの小窓。メニューバーのアイコンの真下に出る。
///
/// 鏡の窓（`MirrorPanel`）と同じく、フォーカスを奪わないパネル（`.nonactivatingPanel`）。
/// 開いても前面のアプリは変わらない。違うのは、枠もタイトルバーも無い（`.borderless`）こと。
/// 大きさを変えることも動かすことも無いので、タイトルバーの形を借りる理由が無い。
/// 角の丸みと、後ろが透ける地は `NSVisualEffectView` に持たせる。
///
/// Esc と ⌘W で閉じるのは、元の `DismissablePanel` がする。
final class CalendarPanel: DismissablePanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // メニューと同じ階層。ほかのアプリの浮いた窓より手前に出す。
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // メニューやポップオーバーと同じ、後ろが透ける地。
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }
}

/// フォーカスを持っていない窓でも、1回目のクリックから日や予定を押せるようにする。
/// 無いと、1回目のクリックは窓を手前に出すだけで食われる。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// カレンダーの小窓を出す・隠す。
@MainActor
final class CalendarController {
    private let model: CalendarModel
    private let panel: CalendarPanel
    private let outsideClicks = OutsideClickWatcher()

    /// 外のクリックとみなさない範囲（画面の座標）。メニューバーの One のアイコン。
    ///
    /// アイコンへのクリックは、One のものなのに外のクリックとしても届く（`OutsideClickWatcher`）。
    /// ここで閉じると、続いてアイコンのクリックの処理（出し入れ）が走って、また開いてしまう。
    /// アイコンの上では閉じずに、出し入れはアイコンの側に任せる。
    var ignoredArea: (() -> NSRect?)? {
        get { outsideClicks.ignoredArea }
        set { outsideClicks.ignoredArea = newValue }
    }

    init(model: CalendarModel) {
        self.model = model
        panel = CalendarPanel(content: FirstMouseHostingView(rootView: CalendarView(model: model)))
        panel.onRequestHide = { [weak self] in self?.hide() }
        outsideClicks.onClick = { [weak self] in self?.hide() }
        model.onOpenedOtherApp = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    /// `anchor`（アイコンの矩形、画面の座標）の真下に出す。出ていれば隠す。
    func toggle(below anchor: NSRect, on screen: NSScreen) {
        if isVisible { hide() } else { show(below: anchor, on: screen) }
    }

    func show(below anchor: NSRect, on screen: NSScreen) {
        model.prepareToShow()
        let frame = PanelPlacement.frame(
            size: panel.frame.size,
            anchorMidX: anchor.midX,
            visibleFrame: screen.visibleFrame,
            margin: 6
        )
        panel.setFrame(frame, display: false)
        // 鏡と同じく、One は前面のアプリではないので前に出してからキーにする（Esc を受けるため）。
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClicks.isActive = true
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        outsideClicks.isActive = false
    }
}
