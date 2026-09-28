import AppKit

/// 左右どちらの Command キーか。
///
/// `enum` は「取りうる値がこれで全部」を型で言える。`String` や `Int` で
/// 表すのと違い、switch の書き漏れをコンパイラが指摘してくれる。
enum CommandSide {
    case left
    case right
}

/// Command キーの「単独押し」を見張る。
///
/// 単独押しとは「⌘ を押して、他のキーもクリックも挟まずにそのまま離した」こと。
/// ⌘C や ⌘⇧4 のときに切り替わってしまうと使い物にならないので、押している間に
/// 何か起きたらその回を無かったことにする（`cancelled`）という作りにしている。
final class CommandKeyWatcher {
    /// 単独押しが成立したときに呼ばれる。
    ///
    /// 関数を値として持つプロパティ。`((CommandSide) -> Void)?` は
    /// TypeScript の `((side: CommandSide) => void) | undefined` と同じ形。
    var onTap: ((CommandSide) -> Void)?

    /// `NSEvent.modifierFlags` は「左右どちらの ⌘ か」を、公開された定数ではなく
    /// 下位のビットで持っている（IOKit の NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK）。
    /// `.command` を見るだけでは左右が分からないので、ここを直接見る。
    private enum Bit {
        static let leftCommand: UInt = 0x0000_0008
        static let rightCommand: UInt = 0x0000_0010
    }

    private var monitor: Any?
    private var localMonitor: Any?
    /// いま押されている ⌘。両手で同時に押される場合があるので集合で持つ。
    private var pressed: Set<CommandSide> = []
    /// 単独押しの候補。押し始めに決まり、離したときに使う。
    private var candidate: CommandSide?
    /// 単独押しではないと分かったか。
    private var cancelled = false

    /// 監視を始める。
    ///
    /// 大事な注意: アクセシビリティの許可が無いとき、この呼び出しは **失敗しない**。
    /// エラーも出さず、ただハンドラが一度も呼ばれない。なので許可が下りたことを
    /// 確かめてから呼ぶ（AppModel 側でやっている）。
    func start() {
        guard monitor == nil else { return }

        // .keyDown やクリックまで見るのは「⌘ を押している間に何か起きたか」を
        // 知るためだけで、それらを止めたり書き換えたりはしない。
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
        ]

        // addGlobalMonitorForEvents は「他のアプリに向かうイベントを覗く」もの。
        // 覗くだけで、イベントを消すことはできない。今回は消す必要が無いのでこれで足りる。
        // [weak self] は循環参照を避けるため。self がクロージャを持ち、クロージャが
        // self を強く持つと、どちらも解放されなくなる。
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.process(event)
        }
        // グローバルモニタには、One 自身に届いたイベントは来ない。鏡の窓はフォーカスを
        // 奪わずにキーになる（Esc を受けるため）ので、開いている間の打鍵は One に届く。
        // そちらも同じ判定に流す。1つのイベントはどちらか片方にしか来ないので、
        // 二重には数えない。イベントはそのまま返して、止めない。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.process(event)
            return event
        }
        log.notice("監視を開始した (登録できた=\(self.monitor != nil, privacy: .public))")
    }

    private func reset() {
        pressed = []
        candidate = nil
        cancelled = false
    }

    /// 受け取ったイベント1つを判定に流す。
    ///
    /// 監視の登録と判定を分けておくと、実際のキーボードを使わずに
    /// 合成した NSEvent を流し込んでテストできる。
    func process(_ event: NSEvent) {
        // イベントが本当に届いているかを確かめるための記録。
        // 打鍵のたびに出るので debug。ディスクには残らない。
        let hex = String(event.modifierFlags.rawValue, radix: 16)
        log.debug("イベント 種別=\(event.type.rawValue, privacy: .public) flags=0x\(hex, privacy: .public)")

        if event.type == .flagsChanged {
            handleFlagsChanged(event)
        } else if !pressed.isEmpty {
            // ⌘ を押している最中の打鍵・クリック。つまりショートカットだった。
            cancelled = true
        }
    }

    /// 修飾キーの状態が変わるたびに呼ばれる。押した瞬間と離した瞬間の両方で来る。
    private func handleFlagsChanged(_ event: NSEvent) {
        let raw = event.modifierFlags.rawValue
        var now: Set<CommandSide> = []
        if raw & Bit.leftCommand != 0 { now.insert(.left) }
        if raw & Bit.rightCommand != 0 { now.insert(.right) }

        // ⌘ 以外の修飾キーが混ざっているか。
        // Caps Lock は入力とは無関係に途中で切り替わりうるので、判定から外す。
        let others = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.command, .capsLock])

        if now.isEmpty {
            // ⌘ が全部離れた。ここまで無傷なら単独押しが成立する。
            if let side = candidate, !cancelled {
                log.debug("単独押しが成立: \(side == .left ? "左" : "右", privacy: .public)")
                onTap?(side)
            } else if candidate != nil {
                log.debug("単独押しではなかったので何もしない")
            }
            reset()
            return
        }

        if pressed.isEmpty {
            // 押し始め。⌘ 以外が既に押されている、あるいは最初から2つ押されて
            // いるなら、この回は対象外。
            candidate = now.count == 1 ? now.first : nil
            cancelled = !others.isEmpty || now.count != 1
        } else if now != pressed || !others.isEmpty {
            // 押している途中で増減した（両手押し）か、他の修飾キーが来た。
            cancelled = true
        }

        pressed = now
    }
}
