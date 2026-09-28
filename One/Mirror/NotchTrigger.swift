import AppKit

/// ノッチのクリックを拾う。
///
/// ノッチの真上に透明な小窓を置き、そこに来たクリックを受け取る。メニューバーより
/// 手前の階層（`.statusBar`）に置くので、ノッチの部分のクリックはメニューバーより先に
/// この小窓に届く。ノッチの部分には画素が無いので、小窓が見えることはない。
///
/// 画面の構成が変わったら（外部ディスプレイの抜き差し、クラムシェル、解像度の変更）
/// 置き直す。ノッチは内蔵ディスプレイにしか無いので、閉じて外部ディスプレイだけで
/// 使っているときは小窓が無くなる。
@MainActor
final class NotchTrigger {
    /// クリックされた。ノッチの矩形と、それがある画面を渡す。
    var onClick: ((CGRect, NSScreen) -> Void)?

    var isEnabled = false {
        didSet { if isEnabled != oldValue { rebuild() } }
    }

    private var panels: [NSPanel] = []

    /// ノッチの無い画面で試すための切り替え。
    ///
    /// ```sh
    /// defaults write com.finalize.one fakeNotch -bool true    # 入れる
    /// defaults delete com.finalize.one fakeNotch              # 戻す
    /// ```
    ///
    /// メインの画面の上端中央（幅 200pt、メニューバーの高さ）に偽のノッチを置く。
    /// 本物と同じく見えないので、メニューバーの真ん中あたりをクリックする。
    /// 変えたらアプリを起動し直す。
    private var usesFakeNotch: Bool { UserDefaults.standard.bool(forKey: "fakeNotch") }

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        guard isEnabled else { return }

        for screen in NSScreen.screens {
            if let rect = NotchGeometry.notchRect(
                screenFrame: screen.frame,
                topInset: screen.safeAreaInsets.top,
                leftWidth: screen.auxiliaryTopLeftArea?.width,
                rightWidth: screen.auxiliaryTopRightArea?.width
            ) {
                log.notice("ノッチを見つけた: \(screen.localizedName, privacy: .public) \(NSStringFromRect(rect), privacy: .public)")
                panels.append(makePanel(rect: rect, screen: screen))
            }
        }

        // メニューバーのある画面が先頭。偽のノッチはそこに置く。
        if panels.isEmpty, usesFakeNotch, let main = NSScreen.screens.first {
            let rect = NotchGeometry.fakeNotchRect(screenFrame: main.frame, height: NSStatusBar.system.thickness)
            log.notice("偽のノッチを置いた: \(main.localizedName, privacy: .public) \(NSStringFromRect(rect), privacy: .public)")
            panels.append(makePanel(rect: rect, screen: main))
        }

        if panels.isEmpty {
            log.notice("ノッチのある画面が無い（画面の数=\(NSScreen.screens.count)）")
        }
    }

    private func makePanel(rect: CGRect, screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = TriggerView()
        view.onClick = { [weak self, screen] in self?.onClick?(rect, screen) }
        panel.contentView = view
        // 透明な窓は、既定では透明な部分のクリックを後ろに素通しする。
        // 明示的に false を入れると、窓全体でクリックを受け取るようになる。
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        return panel
    }
}

private final class TriggerView: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        // 見た目は透明。ただし完全な透明（塗り無し）にはしない。塗りが一切無い窓は
        // クリックが後ろに素通りすることがあるので、目に見えない濃さで塗っておく。
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 透明な窓にクリックが本当に届いているかは、見た目では分からない。ログで確かめる。
        log.notice("ノッチがクリックされた")
        onClick?()
    }
}
