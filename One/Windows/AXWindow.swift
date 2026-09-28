import AppKit
import ApplicationServices

/// 他のアプリのウィンドウ1枚。
///
/// 他のアプリのウィンドウを動かす手段は、macOS では Accessibility API（AX で始まる
/// C の API）しか無い。本来は画面読み上げなどの支援技術のための API で、
/// 「このウィンドウの位置はいくつか」「位置をこう変えてくれ」をアプリに頼める。
/// アクセシビリティの許可が要るのはこのため。⌘ の単独押しを見るのと同じ許可で足りる。
///
/// C の API の面倒さ（CFTypeRef、AXValue への詰め替え）はこの型に閉じ込めて、
/// 呼ぶ側は `frame` と `setFrame(_:)` だけで済むようにしている。`InputSource` と同じ考え方。
///
/// 座標は AX の座標系（主画面の左上が原点、y は下向き）。`ScreenArea` と同じ。
struct AXWindow {
    /// ウィンドウを指す AX の要素。
    ///
    /// 同じウィンドウなら、何度取り直しても `==` で等しい（中で CFEqual が呼ばれる）。
    /// 「元に戻す」の記録はこれをキーにして引いている。
    let element: AXUIElement
    /// ウィンドウの持ち主のアプリ。
    let app: AXUIElement
    /// ログに出す、持ち主のアプリの名前。
    let appID: String

    /// AX の呼び出しを待つ上限（秒）。
    ///
    /// AX の呼び出しは相手のアプリに問い合わせて返事を待つ。相手が固まっていると
    /// 既定では何秒も返ってこず、その間 One のメインスレッドも止まる。One は ⌘ の
    /// 単独押しも同じスレッドで見ているので、ウィンドウを動かそうとしただけで
    /// 英かなの切り替えまで効かなくなる。それよりは動かすのを諦める。
    private static let timeout: Float = 0.5

    /// いま手前にあるアプリの、キー入力を受けているウィンドウ。
    ///
    /// One はメニューバーだけのアプリで、メニューを開いても手前のアプリは入れ替わらない。
    /// なので、ショートカットから呼んでもメニューから呼んでも、利用者が操作していた
    /// ウィンドウが取れる。
    static func focused() -> AXWindow? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)

        // キー入力を受けているウィンドウが無いとき（パネルだけ開いている等）は、
        // そのアプリの主となるウィンドウで代える。
        guard let window = element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, timeout)
        return AXWindow(element: window, app: app, appID: running.bundleIdentifier ?? "pid \(running.processIdentifier)")
    }

    /// 画面のその位置にあるウィンドウ。手前にあるかどうかは問わない。
    ///
    /// ドラッグでのスナップに使う。マウスを押した場所で呼び、どのウィンドウを
    /// 掴んだかを知る。⌘ を押しながら後ろのウィンドウを動かすこともできるので、
    /// 手前のアプリのウィンドウとは限らない。
    ///
    /// その位置にある部品（ボタンや文字など）を取り、それが属するウィンドウを辿る。
    static func at(_ point: CGPoint) -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        let window: AXUIElement
        if (copy(hit, kAXRoleAttribute) as? String) == kAXWindowRole {
            window = hit
        } else if let owner = element(hit, kAXWindowAttribute) {
            window = owner
        } else {
            // メニューバーや Dock、デスクトップなど、ウィンドウに属さないもの。
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetMessagingTimeout(window, timeout)
        let appID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        return AXWindow(element: window, app: app, appID: appID)
    }

    // MARK: - 読む

    /// いまの位置と大きさ。読めなければ nil。
    var frame: CGRect? {
        guard let origin = Self.point(element, kAXPositionAttribute),
              let size = Self.size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// 大きさを変えられるか。計算機やシステム設定のように、大きさが決まっているウィンドウもある。
    var isResizable: Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    /// フルスクリーンになっているか。
    ///
    /// フルスクリーンのウィンドウは専用のスペースにいて、位置を書き換えても意味が無い
    /// （アプリによっては崩れる）。属性の名前は公開のヘッダに定数が無いので文字列で書く。
    var isFullScreen: Bool {
        Self.bool(element, "AXFullScreen") ?? false
    }

    // MARK: - 書く

    /// 位置と大きさを変える。
    ///
    /// **大きさ → 位置 → 大きさ の順に3回書く。** 1回ずつでは足りない場面がある:
    ///
    /// - 先に位置だけ変えると、大きいままのウィンドウを画面の端へ寄せることになり、
    ///   はみ出す分を macOS が勝手に詰めてしまう。
    /// - 先に大きさだけ変えると、今いる場所で大きくしようとして、画面の端で止められる。
    ///
    /// 最初の「大きさ」で今いる場所で入る大きさにし、「位置」で行き先へ動かし、
    /// 最後の「大きさ」で行き先で本来の大きさにする。Rectangle も同じ順で書いている。
    func setFrame(_ frame: CGRect) {
        // 大きさを変えられないウィンドウに大きさを書くと、失敗が返ってくるだけなので書かない。
        let resizable = isResizable
        withoutEnhancedUserInterface {
            if resizable { write(kAXSizeAttribute, size: frame.size) }
            write(kAXPositionAttribute, point: frame.origin)
            if resizable { write(kAXSizeAttribute, size: frame.size) }
        }
    }

    /// 位置は変えずに、大きさだけ変える。
    ///
    /// ドラッグの最中に使う。ウィンドウはドラッグで動いている最中なので、位置まで書くと
    /// カーソルの動きと取り合いになる。
    func resize(to size: CGSize) {
        withoutEnhancedUserInterface {
            write(kAXSizeAttribute, size: size)
        }
    }

    /// 大きさは変えずに、位置だけ変える。
    func move(to origin: CGPoint) {
        withoutEnhancedUserInterface {
            write(kAXPositionAttribute, point: origin)
        }
    }

    /// アプリの `AXEnhancedUserInterface` を切った状態で `body` を行う。
    ///
    /// 支援技術（VoiceOver など）が動いていると、アプリにこの属性が立てられることがある。
    /// 立っていると、Chrome や Electron 製のアプリなどが位置や大きさの変更を
    /// アニメーションさせるようになり、続けて書いた値がアニメーションの途中で
    /// 上書きされて、大きさが中途半端なまま止まる。
    ///
    /// 書いている間だけ切って、終わったら元に戻す。Rectangle をはじめ、他の
    /// ウィンドウ整理アプリも同じことをしている。
    private func withoutEnhancedUserInterface(_ body: () -> Void) {
        let key = "AXEnhancedUserInterface"
        let wasOn = Self.bool(app, key) ?? false
        if wasOn { AXUIElementSetAttributeValue(app, key as CFString, kCFBooleanFalse) }
        body()
        if wasOn { AXUIElementSetAttributeValue(app, key as CFString, kCFBooleanTrue) }
    }

    private func write(_ attribute: String, point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        report(AXUIElementSetAttributeValue(element, attribute as CFString, axValue), attribute)
    }

    private func write(_ attribute: String, size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        report(AXUIElementSetAttributeValue(element, attribute as CFString, axValue), attribute)
    }

    /// 書き込みに失敗したら残す。失敗は珍しく、あとから「このアプリだけ動かない」を
    /// 追うときに要る。
    private func report(_ error: AXError, _ attribute: String) {
        guard error != .success else { return }
        log.error("ウィンドウに書き込めない \(attribute, privacy: .public) AXError=\(error.rawValue, privacy: .public) アプリ=\(appID, privacy: .public)")
    }

    // MARK: - C の API から値を取り出す部分

    /// 属性を CFTypeRef のまま読む。
    ///
    /// `AXUIElementCopyAttributeValue` は名前のとおり Copy で、受け取った値の所有権は
    /// こちらに移る。この関数は型の付いた `CFTypeRef` を返し、所有権の約束もヘッダに
    /// 書かれているので、Swift が解放まで面倒を見てくれる。`Unmanaged` は要らない。
    /// （`InputSource` で要ったのは、`TISGetInputSourceProperty` が型の無い生ポインタを
    /// 返すので、所有権を自分で宣言するしかなかったから。）
    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // 型は上で確かめたので、強制キャストで落ちることは無い。
        return (value as! AXUIElement)
    }

    /// 位置や大きさは AXValue という箱に入って返ってくる。中身の型を確かめてから取り出す。
    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}
