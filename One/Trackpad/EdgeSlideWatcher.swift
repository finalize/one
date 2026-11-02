import AppKit

/// トラックパッドに触れている指を見張り、端をなぞったら音量・キーボードの明るさのキーを送る。
///
/// 指の位置は、ジェスチャーのイベント（`NSEvent.EventType.gesture`）に載っている。トラックパッドに
/// 指が触れている間、macOS はこれを細かく（1秒に何十回も）流していて、指1本でポインタを動かして
/// いるだけでも来る。判断は `EdgeSlideTracker` に任せ、言われた段数だけキーを送る。
///
/// ⌘ やドラッグの見張りと違い、`NSEvent.addGlobalMonitorForEvents` ではなくイベントタップ
/// （`CGEvent.tapCreate`）で受ける。グローバルモニタには、ジェスチャーのイベントが1つも来なかった
/// （Magic Trackpad の端を 30 回ほどなぞる間、タップには 700 回あまり来て、モニタには 0 回。2026-11-02）。
/// タップでも覗くだけ（`.listenOnly`）で、イベントは消さない。なので、なぞっている間はポインタも動く。
final class EdgeSlideWatcher {
    private var tracker = EdgeSlideTracker()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    deinit {
        stop()
    }

    /// 見張りを始める。アクセシビリティの許可が下りてから呼ぶ。
    func start() {
        guard tap == nil else { return }
        // クリックも見るのは、なぞっている途中でクリックしたらその回をやめるため。押しているかは指の位置を
        // 受け取るたびにも見ているが、それは「今」の状態で、届くのが遅れたイベントと順番がそろわない。
        // 同じタップで受ければ、指の位置と同じ順で届く。
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(1) << CGEventMask(NSEvent.EventType.gesture.rawValue)) {
            $0 | CGEventMask(1) << CGEventMask($1.rawValue)
        }
        // C の関数として渡すので、クロージャは外の変数をつかめない。self は userInfo で渡して取り出す。
        // self を手放さずに渡す（passUnretained）。stop で外すので、外した後に呼ばれることは無い。
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<EdgeSlideWatcher>.fromOpaque(userInfo).takeUnretainedValue().receive(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("トラックパッドの見張りを始められなかった")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        log.notice("トラックパッドの端の見張りを始めた")
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        tracker = EdgeSlideTracker()
        log.notice("トラックパッドの端の見張りをやめた")
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 応答が遅い・ユーザーの操作で、macOS がタップを止めることがある。止まったら掛け直す。
            // 止まっている間に何があったか（2本目の指、クリック、指が触れ始めたこと）は分からないので、
            // 見張りを始め直したのと同じにする。なぞっている回はやめ、そのとき触れている指は、触れ始めたと
            // macOS が教える指でなければ相手にしない。
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            tracker = EdgeSlideTracker()
            log.notice("トラックパッドの見張りが止められたので掛け直した")
            return
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            tracker.interrupt()
            return
        default:
            break
        }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .gesture else { return }
        // touching は、触れ始めた・動いた・止まっている指。離れた指は入らない。
        let touches = nsEvent.touches(matching: .touching, in: nil).compactMap { touch -> TrackpadTouch? in
            guard let id = touch.identity as? NSObject else { return nil }
            return TrackpadTouch(
                id: AnyHashable(id),
                x: Double(touch.normalizedPosition.x),
                y: Double(touch.normalizedPosition.y),
                isResting: touch.isResting,
                began: touch.phase.contains(.began)
            )
        }

        guard let change = tracker.update(touches, isPressing: NSEvent.pressedMouseButtons != 0) else { return }
        let up = change.steps > 0
        let (key, name): (MediaKey, String) = switch change.edge {
        case .right: (up ? .volumeUp : .volumeDown, "音量")
        case .left: (up ? .keyboardBrightnessUp : .keyboardBrightnessDown, "キーボードの明るさ")
        }
        for _ in 0 ..< abs(change.steps) {
            key.press()
        }
        // なぞるたびに出るので debug。ディスクには残らない。
        log.debug("端をなぞった \(name, privacy: .public) \(change.steps, privacy: .public) 段")
    }
}
