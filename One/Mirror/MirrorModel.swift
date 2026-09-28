import AppKit
import AVFoundation

/// 鏡（ノッチのクリックで出る、カメラの映像の窓）の部品をつなぎ、メニューと設定の窓に状態を見せる。
///
/// 元は Kagami という別のアプリだった。カメラ・ノッチ・鏡の窓はそのまま持ってきて、
/// Kagami の AppDelegate がしていた「部品をつなぐ」と「メニュー」をここに移した。
/// Kagami にあったメニューバーのアイコンは持ってきていない。鏡は One のアイコンの右クリックの
/// メニューから開き、設定は One の設定の窓の「鏡」タブ（`MirrorSettings`）で変える。
///
/// `AppModel` に混ぜずに分けたのは、部品がどれも `@MainActor`（メインスレッドでだけ触る、
/// という印）で書かれているから。印の無い `AppModel` の init からは作れない。
@MainActor
@Observable
final class MirrorModel {
    private let camera = Camera()
    private let notch = NotchTrigger()
    private let controller: MirrorController

    /// 変わったかもしれない、の合図。
    ///
    /// 下の値はどれもこの class が自分では持たず、読まれるたびに本当の持ち主
    /// （UserDefaults・カメラ・窓）に聞く。ところが `@Observable` が追えるのは、
    /// この class が自分で持っているプロパティだけで、持ち主の側で値が変わっても
    /// メニューや設定の窓は古いまま残る。
    ///
    /// そこで、どの値も読む前にこれを読み（`read`）、何か変わったらこれを進める（`bump`）。
    /// SwiftUI は「revision を読んだ」と覚えるので、進めれば描き直される。
    /// 値ごとに見分けずに全部まとめて描き直させるが、項目が十個ほどなので気にしない。
    private var revision = 0

    private enum Keys {
        static let opensFromNotch = "notchTrigger"
    }

    init() {
        UserDefaults.standard.register(defaults: [Keys.opensFromNotch: true])
        controller = MirrorController(camera: camera)

        // unowned は weak と同じく循環参照を切るが、nil にならない前提で使う。
        // MirrorModel はアプリが終わるまで生きているので、こちらで足りる。
        controller.menuProvider = { [unowned self] in makeMenu() }
        controller.onChange = { [unowned self] in bump() }
        notch.onClick = { [unowned self] rect, screen in
            controller.toggle(at: .init(midX: rect.midX, screen: screen))
        }
        notch.isEnabled = UserDefaults.standard.bool(forKey: Keys.opensFromNotch)

        // カメラの抜き差しでメニューのカメラの一覧を描き直す。映していないときは
        // カメラの側から合図が来ない（`onChange` は映しているときだけ）ので、ここで拾う。
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bump() }
            }
        }
    }

    private func read<T>(_ value: () -> T) -> T {
        _ = revision
        return value()
    }

    private func bump() {
        revision += 1
    }

    // MARK: - メニューから読む・変える

    var isVisible: Bool { read { controller.isVisible } }

    var isMirrored: Bool {
        get { read { controller.isMirrored } }
        set { controller.isMirrored = newValue; bump() }
    }

    /// 外をクリックしても閉じない。
    var isPinned: Bool {
        get { read { controller.isPinned } }
        set { controller.isPinned = newValue; bump() }
    }

    var opensFromNotch: Bool {
        get { read { notch.isEnabled } }
        set {
            notch.isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.opensFromNotch)
            bump()
        }
    }

    /// 選べるカメラ。
    var cameras: [(id: String, name: String)] {
        read { camera.devices.map { (id: $0.uniqueID, name: $0.localizedName) } }
    }

    /// 選んだカメラ。nil は「自動」（macOS がおすすめするカメラ）。
    ///
    /// 選んであったカメラが抜かれていたら nil を返す。そのとき実際に映るのは自動と同じ
    /// 選び方のカメラなので、メニューでも「自動」に印を付ける。保存してある値は消さない
    /// （挿し直したら、そのカメラに戻ってほしい）。
    var cameraID: String? {
        get {
            read {
                let id = camera.selectedDeviceID
                return camera.devices.contains { $0.uniqueID == id } ? id : nil
            }
        }
        set { camera.selectedDeviceID = newValue; bump() }
    }

    var quality: Quality {
        get { read { camera.preferredQuality } }
        set { camera.preferredQuality = newValue; bump() }
    }

    /// 今のカメラでその画質を選べるか。選べない段はメニューで灰色にする。
    func supports(_ quality: Quality) -> Bool {
        read {
            guard let device = camera.currentDevice else { return quality == .auto }
            return camera.supports(quality, on: device)
        }
    }

    /// 実際に流れている解像度（"1920×1080" など）。映していないときは nil。
    var activeResolution: String? {
        read { controller.isVisible && camera.state == .running ? camera.activeResolution : nil }
    }

    // MARK: - 出す・隠す

    /// `midX` の真下（その画面の、メニューバーのすぐ下）に出す。出ていれば隠す。
    /// メニューバーのアイコンの右クリックのメニューから、アイコンの下に出すのに使う。
    func toggle(midX: CGFloat, on screen: NSScreen) {
        controller.toggle(at: .init(midX: midX, screen: screen))
    }

    /// 設定の窓の「鏡を出して確かめる」から出し入れする。窓はマウスの真下（の画面の上端）に出す。
    func toggleUnderMouse() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        controller.toggle(at: .init(midX: point.x, screen: screen))
    }

    // MARK: - 鏡の上で右クリックしたときのメニュー

    /// 開くたびに作り直す。カメラの抜き差しや画質の対応は、開いた時点のものを出したい。
    ///
    /// 設定の窓の「鏡」タブ（`MirrorSettings`）と同じ項目を、AppKit の `NSMenu` で組み直している。
    /// SwiftUI で書いたメニューを NSView の右クリックに渡す道（`NSHostingMenu`）は
    /// macOS 15 からで、One は 14 でも動かしたい。
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem("隠す") { [unowned self] in controller.hide() })
        menu.addItem(.separator())

        menu.addItem(submenu("カメラ", cameraMenu()))
        menu.addItem(submenu("画質", qualityMenu()))
        menu.addItem(ClosureMenuItem("鏡像にする", checked: isMirrored) { [unowned self] in isMirrored.toggle() })
        menu.addItem(ClosureMenuItem("外をクリックしても閉じない", checked: isPinned) { [unowned self] in isPinned.toggle() })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("ノッチのクリックで開く", checked: opensFromNotch) { [unowned self] in opensFromNotch.toggle() })
        return menu
    }

    private func cameraMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let selected = cameraID

        menu.addItem(ClosureMenuItem("自動", checked: selected == nil) { [unowned self] in cameraID = nil })
        menu.addItem(.separator())

        let cameras = cameras
        if cameras.isEmpty {
            let none = NSMenuItem(title: "カメラが見つかりません", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for entry in cameras {
            menu.addItem(ClosureMenuItem(entry.name, checked: entry.id == selected) { [unowned self] in cameraID = entry.id })
        }
        return menu
    }

    private func qualityMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let preferred = quality

        for option in Quality.allCases {
            let entry = ClosureMenuItem(option.label, checked: option == preferred) { [unowned self] in quality = option }
            // 今のカメラで使えない段は灰色にする。選んであったのに使えない場合は、
            // チェックは残したまま自動で映す（Quality.effective）。
            entry.isEnabled = supports(option)
            menu.addItem(entry)
        }

        if let resolution = activeResolution {
            menu.addItem(.separator())
            let now = NSMenuItem(title: "いま映っている: \(resolution)", action: nil, keyEquivalent: "")
            now.isEnabled = false
            menu.addItem(now)
        }
        return menu
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
