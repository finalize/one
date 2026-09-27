import AppKit
import Carbon.HIToolbox
import SwiftUI

/// カレンダーの小窓。メニューバーのアイコンの真下に出る。
///
/// 鏡の窓（`MirrorPanel`）と同じく、フォーカスを奪わないパネル（`.nonactivatingPanel`）。
/// 開いても前面のアプリは変わらない。違うのは、枠もタイトルバーも無い（`.borderless`）こと。
/// 大きさを変えることも動かすことも無いので、タイトルバーの形を借りる理由が無い。
/// 角の丸みと、後ろが透ける地は `NSVisualEffectView` に持たせる。
final class CalendarPanel: NSPanel {
    /// Esc か ⌘W が押された。
    var onRequestHide: (() -> Void)?

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

    /// 枠の無い窓は、既定ではキーになれない。Esc を受けたいのでなれるようにする。
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onRequestHide?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            onRequestHide?()
            return true
        }
        return super.performKeyEquivalent(with: event)
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
    private var outsideClickMonitor: Any?

    /// 外のクリックとみなさない範囲（画面の座標）。メニューバーの One のアイコン。
    ///
    /// アイコンへのクリックは、One のものなのに外のクリックとしてグローバルモニタにも届く
    /// （鏡で確かめた。`MirrorController` の注釈）。ここで閉じると、続いてアイコンの
    /// クリックの処理（出し入れ）が走って、また開いてしまう。アイコンの上では閉じずに、
    /// 出し入れはアイコンの側に任せる。
    var ignoredArea: (() -> NSRect?)?

    init(model: CalendarModel) {
        self.model = model
        panel = CalendarPanel(content: FirstMouseHostingView(rootView: CalendarView(model: model)))
        panel.onRequestHide = { [weak self] in self?.hide() }
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
        updateOutsideClickMonitor()
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        updateOutsideClickMonitor()
    }

    private func updateOutsideClickMonitor() {
        if isVisible, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let area = self.ignoredArea?(), area.contains(NSEvent.mouseLocation) { return }
                    self.hide()
                }
            }
        } else if !isVisible, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
