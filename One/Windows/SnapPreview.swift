import AppKit

/// ドラッグ中に、離せばどこへ置かれるかを見せる半透明の枠。
///
/// 見た目は Rectangle の既定に合わせた（黒の塗りに明るい灰色の縁、全体を 30% の濃さで）。
/// 明るい壁紙でも暗い壁紙でも、下が透けたまま「ここに来る」が分かる。
///
/// One が自分で出す唯一のウィンドウ。クリックを受けず、キーも受けず、⌘Tab にも出ない。
/// 出ているあいだも、ドラッグしているウィンドウの操作を邪魔しない。
final class SnapPreview {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0.3
        // ふつうのウィンドウより上。ドラッグしているウィンドウの上に重ねて見せる。
        window.level = .modalPanel
        // どのスペースにいても出る、⌘Tab やウィンドウの一覧に出ない。
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.cgColor
        box.layer?.borderColor = NSColor.lightGray.cgColor
        box.layer?.borderWidth = 2
        // macOS 26 からウィンドウの角が大きく丸くなったので、それに揃える。
        if #available(macOS 26, *) {
            box.layer?.cornerRadius = 16
        } else {
            box.layer?.cornerRadius = 10
        }
        window.contentView = box
    }

    /// `frame`（AX の座標）に枠を出す。出ていれば動かす。
    func show(_ frame: CGRect) {
        // NSWindow の位置は AppKit の座標で渡す。
        guard let primary = NSScreen.screens.first else { return }
        window.setFrame(frame.flipped(primaryHeight: primary.frame.height), display: true)
        // One は手前のアプリにならない。手前のアプリかどうかに関わらず、同じ階層の
        // いちばん上に出す。キー入力の宛先は奪わない。
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
