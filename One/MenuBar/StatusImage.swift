import AppKit

/// メニューバーの ⌘ のアイコンに、モード（A / あ）とモニタの数字を並べた1枚の画像。
///
/// `NSStatusItem` のボタンが持てるのは、画像1枚と1行の文字だけ。数字を上下2段に並べるには、
/// 全部を1枚の画像に描いて載せるしかない。テンプレート画像にするので、メニューバーの明暗に
/// 合わせて macOS が色を変える（ほかのアイコンと同じ白か黒になる）。
enum StatusImage {
    /// 数字の字。数字の幅がそろう字（monospacedDigit）にする。そうしないと 1 と 8 で幅が違い、
    /// 1秒ごとに文字が左右に揺れる。
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let modeFont = NSFont.menuBarFont(ofSize: 0)
    private static let gap: CGFloat = 5

    /// - mode: ⌘ の右に出すモードの字（A / あ）。出さないなら nil
    /// - columns: `Monitor.columns` で2段に詰めた行
    /// - height: メニューバーの高さ
    static func make(mode: String?, columns: [[Monitor.Line]], height: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: "command", accessibilityDescription: "One") ?? NSImage()
        let modeText = mode.map { NSAttributedString(string: $0, attributes: [.font: modeFont]) }
        let widths = columns.map(columnWidth)

        var width = symbol.size.width
        if let modeText { width += 3 + modeText.size().width }
        for columnWidth in widths { width += gap + columnWidth }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            var x: CGFloat = 0
            symbol.draw(in: NSRect(
                x: x, y: (rect.height - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            ))
            x += symbol.size.width

            if let modeText {
                let size = modeText.size()
                x += 3
                modeText.draw(at: NSPoint(x: x, y: (rect.height - size.height) / 2))
                x += size.width
            }

            // 2段の高さを真ん中に置く。1行だけの列は、その1行を真ん中に置く。
            let rowHeight = ceil(valueFont.ascender - valueFont.descender)
            for (column, columnWidth) in zip(columns, widths) {
                x += gap
                let top = (rect.height + CGFloat(column.count) * rowHeight) / 2
                for (row, line) in column.enumerated() {
                    let y = top - CGFloat(row + 1) * rowHeight
                    NSAttributedString(string: line.text, attributes: [.font: valueFont])
                        .draw(at: NSPoint(x: x, y: y))
                }
                x += columnWidth
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 列の幅。その列の行の種類に来うる、一番長い書き方で決める。
    ///
    /// 今の数字の幅で決めると、「9.9 MB/s」から「12 MB/s」に変わるたびに画像の幅が変わり、
    /// メニューバーのほかのアイコンが左右に揺れる。
    static func columnWidth(_ column: [Monitor.Line]) -> CGFloat {
        column.map { widest(for: $0.kind) }.max() ?? 0
    }

    private static func widest(for kind: Monitor.Line.Kind) -> CGFloat {
        let samples: [String] = switch kind {
        case .down: ["↓ 999 KB/s", "↓ 999 MB/s", "↓ 999 GB/s", "↓ 9.9 MB/s"]
        case .up: ["↑ 999 KB/s", "↑ 999 MB/s", "↑ 999 GB/s", "↑ 9.9 MB/s"]
        case .cpu: ["CPU 100%"]
        case .memory: ["メモリ 100%"]
        case .disk: ["空き 999 GB", "空き 999 TB", "空き 999 MB"]
        }
        return ceil(samples.map { NSAttributedString(string: $0, attributes: [.font: valueFont]).size().width }.max() ?? 0)
    }
}
