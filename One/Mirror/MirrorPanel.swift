import AppKit
import AVFoundation
import Carbon.HIToolbox

/// 鏡の窓。
///
/// `NSPopover` にしなかったのは、ポップオーバーはユーザーが端を掴んで大きさを変えられないから。
/// 代わりに、フォーカスを奪わないパネルを使う:
///
/// - `.nonactivatingPanel` … 開いても One が前面のアプリにならない。ビデオ会議のアプリを
///   前面に置いたまま、自分の顔だけ確かめられる。Spotlight の窓と同じ種類
/// - `.titled` + 透明なタイトルバー … 見た目は枠無しだが、角丸・影・端を掴んでのリサイズは
///   普通の窓のものがそのまま使える。`.borderless` にするとリサイズが効かない
/// - `.floating` … 他の窓より手前に出る
final class MirrorPanel: NSPanel {
    /// Esc か ⌘W が押された。
    var onRequestHide: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        // どのデスクトップにいても、全画面のビデオ会議の上にも出す。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSPanel は既定で「アプリが後ろに回ったら隠れる」。隠すのは One が決める
        // （隠すときにカメラも止めたい）ので切っておく。
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .black
        minSize = NSSize(width: 160, height: 100)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onRequestHide?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// One はメニューバーだけのアプリで、⌘W を「窓を閉じる」につなぐメニューを当てにできない。
    /// ここで拾い、Esc と同じくカメラも止める道を通す。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            onRequestHide?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// カメラの映像を映す面。
///
/// `makeBackingLayer` でビューの土台のレイヤーそのものをプレビューにしている。
/// サブレイヤーとして足すと、窓のリサイズのたびに自分で大きさを合わせ、
/// 暗黙のアニメーションも止める必要が出る。土台にすれば AppKit が面倒を見る。
final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    var isMirrored = true {
        didSet { applyMirroring() }
    }

    /// 右クリックで出すメニュー。
    var menuProvider: (() -> NSMenu)?

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        // 窓の縦横比は自由に変えられるので、映像は切り抜いて面いっぱいに敷く。
        // 黒帯を出す（.resizeAspect）より鏡らしい。
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { previewLayer }

    /// 鏡像にする。
    ///
    /// 接続はセッションに入力が入ったときに作られ、入力を差し替えると作り直される。
    /// なので設定したら終わりではなく、組み替えのたびに呼ぶ（`Camera.onConfigured`）。
    ///
    /// 自動のままだと、macOS は前面カメラでも鏡像にしないことがある。
    /// 自動を切ってから明示的に決める。
    func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isMirrored
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// 非アクティブな窓でも、最初のクリックからドラッグで動かせるように。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 鏡の窓を出す・隠す・大きさを覚える。
@MainActor
final class MirrorController: NSObject {
    /// 窓をどこの下に出すか。
    struct Anchor {
        var midX: CGFloat
        var screen: NSScreen
    }

    private let camera: Camera
    private let panel = MirrorPanel()
    private let preview: PreviewView
    private let message = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "システム設定を開く", target: nil, action: nil)
    private var outsideClickMonitor: Any?

    private enum Keys {
        static let width = "panelWidth"
        static let height = "panelHeight"
        static let mirrored = "mirrored"
        static let pinned = "pinned"
    }

    var isVisible: Bool { panel.isVisible }

    /// 出した・隠した、カメラの状態や画質が変わった、のどれかで呼ばれる。
    ///
    /// One のメニューと設定の窓は SwiftUI で書いてあり、ここの値の変化を自分では追えない。
    /// これを合図に描き直させる（`MirrorModel`）。
    var onChange: (() -> Void)?

    /// 鏡の上で右クリックしたときに出すメニュー。開くたびに呼ぶ。
    var menuProvider: (() -> NSMenu)? {
        get { preview.menuProvider }
        set { preview.menuProvider = newValue }
    }

    var isMirrored: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.mirrored) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.mirrored)
            preview.isMirrored = newValue
        }
    }

    /// 外をクリックしても閉じない。
    var isPinned: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.pinned) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.pinned)
            updateOutsideClickMonitor()
        }
    }

    init(camera: Camera) {
        UserDefaults.standard.register(defaults: [
            Keys.mirrored: true,
            Keys.width: 400.0,
            Keys.height: 250.0,
        ])
        self.camera = camera
        preview = PreviewView(session: camera.session)
        super.init()
        preview.isMirrored = UserDefaults.standard.bool(forKey: Keys.mirrored)

        buildContent()

        panel.onRequestHide = { [weak self] in self?.hide() }
        camera.onConfigured = { [weak self] in
            self?.preview.applyMirroring()
            self?.onChange?()
        }
        camera.onStateChange = { [weak self] state in
            self?.render(state)
            self?.onChange?()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSize() }
        }
    }

    private func buildContent() {
        preview.translatesAutoresizingMaskIntoConstraints = false

        message.textColor = .white
        message.alignment = .center
        message.font = .systemFont(ofSize: 13, weight: .medium)

        settingsButton.target = self
        settingsButton.action = #selector(openCameraSettings)
        settingsButton.bezelStyle = .rounded

        let stack = NSStackView(views: [message, settingsButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(preview)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.topAnchor.constraint(equalTo: root.topAnchor),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
        ])
        panel.contentView = root
        render(camera.state)
    }

    // MARK: - 出す・隠す

    func toggle(at anchor: Anchor) {
        if isVisible { hide() } else { show(at: anchor) }
    }

    func show(at anchor: Anchor) {
        let saved = CGSize(
            width: UserDefaults.standard.double(forKey: Keys.width),
            height: UserDefaults.standard.double(forKey: Keys.height)
        )
        let frame = PanelPlacement.frame(
            size: saved,
            anchorMidX: anchor.midX,
            visibleFrame: anchor.screen.visibleFrame
        )
        panel.setFrame(frame, display: false)
        // One は前面のアプリではないので、makeKeyAndOrderFront だけだと
        // 他のアプリの窓の後ろに出ることがある。前に出してからキーにする（Esc を受けるため）。
        panel.orderFrontRegardless()
        panel.makeKey()
        camera.start()
        updateOutsideClickMonitor()
        onChange?()
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        camera.stop()
        updateOutsideClickMonitor()
        onChange?()
    }

    /// 外をクリックしたら閉じる。
    ///
    /// 窓がキーでなくなったこと（resignKey）では判定しない。フォーカスを奪わないパネルは
    /// キーになったりならなかったりが状況で揺れるうえ、メニューバーのアイコンやノッチを
    /// クリックしたときに「閉じた直後にトグルでまた開く」が起きやすい。
    ///
    /// グローバルモニタは **他のアプリ宛て**のクリックしか受け取らない。ノッチの小窓や
    /// 鏡そのもの（右クリックのメニュー）は One の窓なのでここに来ず、トグルとぶつからない。
    ///
    /// ただしメニューバーの One のアイコン（⌘）へのクリックは、One のものなのにここに来る
    /// （macOS 27 で確かめた）。なので One のメニューを開くと鏡は閉じる。ほかの外のクリックと
    /// 同じ扱いで困らないので、そのままにしてある。見ながら画質などを変えるなら鏡の上で右クリック。
    /// マウスのクリックを見るだけならアクセシビリティの許可は要らない。
    private func updateOutsideClickMonitor() {
        let wants = isVisible && !isPinned
        if wants, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        } else if !wants, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func saveSize() {
        let size = panel.frame.size
        UserDefaults.standard.set(Double(size.width), forKey: Keys.width)
        UserDefaults.standard.set(Double(size.height), forKey: Keys.height)
    }

    // MARK: - 映せないときの表示

    private func render(_ state: Camera.State) {
        let text: String? = switch state {
        case .stopped, .running: nil
        case .starting: "カメラを起動しています…"
        case .denied: "カメラの使用が許可されていません"
        case .noDevice: "カメラが見つかりません"
        case .failed(let reason): "カメラを開けませんでした\n\(reason)"
        }
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        settingsButton.isHidden = state != .denied
    }

    @objc private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
