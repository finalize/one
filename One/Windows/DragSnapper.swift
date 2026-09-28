import AppKit
import Carbon

/// ウィンドウをドラッグで画面の端へ寄せたら、そこに並べる。
///
/// マウスのイベントを覗き、判断は `SnapTracker` に任せ、言われたことを行う。
/// ⌘ の単独押しを見る `CommandKeyWatcher` と同じく、覗くだけでイベントは消さない。
/// ドラッグそのものは macOS（とアプリ）がふつうに行い、One は離した瞬間に置き直すだけ。
final class DragSnapper {
    private let arranger: WindowArranger
    private let preview = SnapPreview()
    private var tracker = SnapTracker()
    private var monitor: Any?

    /// いま押しているウィンドウ。置くときと、スナップを外すときに使う。
    private var window: AXWindow?
    /// 同じウィンドウの、ウィンドウサーバーでの番号。ドラッグ中の位置を読むのに使う。
    private var windowID: CGWindowID?
    /// 押した時点の画面。ドラッグの最中に画面の構成は変わらないので、毎回は取り直さない。
    private var screens: [ScreenArea] = []

    init(arranger: WindowArranger) {
        self.arranger = arranger
    }

    /// 見張りを始める。アクセシビリティの許可が下りてから呼ぶ。
    func start() {
        guard monitor == nil else { return }
        // Esc（keyDown）は、ドラッグの最中にスナップを取り消すため。
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        log.notice("ドラッグでのスナップを始めた")
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        preview.hide()
        tracker = SnapTracker()
        window = nil
        log.notice("ドラッグでのスナップをやめた")
    }

    private func handle(_ event: NSEvent) {
        // `CGEvent.location` は主画面の左上が原点・y は下向きで、AX の座標と同じ。
        // `NSEvent.mouseLocation` は AppKit の座標なので使わない。
        guard let point = event.cgEvent?.location else { return }

        switch event.type {
        case .leftMouseDown:
            // クリックのたびに、押した場所のウィンドウを調べる。動き出してから調べると、
            // 動く前の枠が取れない（もう動いている）。動く前の枠は、スナップを外すときと
            // 「元に戻す」の出発点に要る。
            screens = ScreenArea.connected
            window = AXWindow.at(point).flatMap { $0.isFullScreen ? nil : $0 }
            // マウスのイベントには、それを受け取るウィンドウの番号が入っている。
            let id = event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
            windowID = id > 0 ? CGWindowID(id) : nil
            tracker.press(at: point, window: initialFrame())
        case .leftMouseDragged:
            run(tracker.drag(to: point, screens: screens) { self.windowID.flatMap(WindowServer.frame(of:)) }, cursor: point)
        case .leftMouseUp:
            run(tracker.release(at: point, screens: screens), cursor: point)
            window = nil
            windowID = nil
        case .keyDown where event.keyCode == UInt16(kVK_Escape):
            run(tracker.cancel(), cursor: point)
        default:
            break
        }
    }

    /// 押したウィンドウの、動く前の枠。
    ///
    /// AX で見つけたウィンドウ（置くのに使う）と、ウィンドウサーバーの番号のウィンドウ
    /// （位置を読むのに使う）が同じものか、枠が一致することで確かめる。食い違うとき
    /// （シートや、アプリが重ねている透明なウィンドウを掴んだ等）は、別のウィンドウを
    /// 動かしてしまわないように、このドラッグは相手にしない。
    private func initialFrame() -> CGRect? {
        guard let axFrame = window?.frame,
              let serverFrame = windowID.flatMap(WindowServer.frame(of:)) else { return nil }
        let same = abs(axFrame.minX - serverFrame.minX) <= 1 && abs(axFrame.minY - serverFrame.minY) <= 1
            && abs(axFrame.width - serverFrame.width) <= 1 && abs(axFrame.height - serverFrame.height) <= 1
        guard same else {
            log.debug("掴んだウィンドウを見分けられないのでスナップしない AX=\(String(describing: axFrame), privacy: .public) サーバー=\(String(describing: serverFrame), privacy: .public)")
            return nil
        }
        return serverFrame
    }

    private func run(_ effects: [SnapTracker.Effect], cursor: CGPoint) {
        guard let window else { return }
        for effect in effects {
            switch effect {
            case let .began(initial, current):
                arranger.unsnap(window, initial: initial, current: current, cursor: cursor)
            case let .preview(snap):
                if let frame = snap.frame { preview.show(frame) }
            case .hidePreview:
                preview.hide()
            case let .place(snap, initial):
                arranger.place(window, snap.action, screens: [snap.screen], from: initial)
            }
        }
    }
}

/// ウィンドウサーバーが持っているウィンドウの枠。
///
/// ドラッグの最中にウィンドウを動かしているのはウィンドウサーバーで、アプリはあとから
/// まとめて知らされる。なので AX でアプリに位置を尋ねると、遅れた値が返ってくる。
/// 試験用のウィンドウで測ると、カーソルが 100pt 近く動いても AX の位置はまだ動いて
/// おらず、0.1 秒ごとにまとめて追いついていた。ウィンドウサーバーの位置はカーソルに
/// ぴったり付いてきていた（2026-09-23）。
///
/// 遅れた位置で「動いているか」を見ると、動き出したことに気づく前にカーソルが
/// `SnapTracker.giveUpDistance` を越えてしまい、ウィンドウのドラッグだと分からない。
/// なのでドラッグ中の位置はこちらで読む。座標は AX と同じ（主画面の左上が原点、y は下向き）。
///
/// ウィンドウの名前を読むには画面収録の許可が要るが、位置と大きさには要らない。
enum WindowServer {
    static func frame(of id: CGWindowID) -> CGRect? {
        // この API の配列の中身は、数（CFNumber）ではなく、ウィンドウの番号をそのまま
        // ポインタの値として詰めたもの。Swift の配列を `as CFArray` で渡すと CFNumber の
        // 配列になり、何も返ってこない。
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}
