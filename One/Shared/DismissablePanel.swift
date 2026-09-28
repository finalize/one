import AppKit
import Carbon.HIToolbox

/// Esc か ⌘W で閉じたいことを持ち主に知らせるパネル。鏡とカレンダーの小窓の元。
///
/// パネル自身は閉じない。閉じるときにカメラを止めるなどの後始末があるので、閉じるのは持ち主に任せる。
/// One はメニューバーだけのアプリで、⌘W を「窓を閉じる」につなぐメニューも当てにできない。
class DismissablePanel: NSPanel {
    /// Esc か ⌘W が押された。
    var onRequestHide: (() -> Void)?

    /// Esc を受けるにはキーになる必要がある。枠の無いパネルは、既定ではキーになれない。
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
