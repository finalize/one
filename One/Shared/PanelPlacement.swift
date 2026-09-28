import CoreGraphics

/// 鏡の窓をどこに出すかの計算。
enum PanelPlacement {
    /// 基準の真下、メニューバーのすぐ下に、画面からはみ出さないように置く。
    ///
    /// - size: 出したい大きさ（前回使っていた大きさ）
    /// - anchorMidX: 窓の真ん中を揃える x。ノッチの中心か、メニューバーのアイコンの中心
    /// - visibleFrame: `NSScreen.visibleFrame`。メニューバーと Dock を除いた範囲
    ///
    /// 画面より大きい窓を覚えていた場合（大きい外部ディスプレイで広げてから MacBook に
    /// 戻ったとき）は、画面に収まるまで縮める。
    static func frame(
        size: CGSize,
        anchorMidX: CGFloat,
        visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let width = min(size.width, visibleFrame.width - margin * 2)
        let height = min(size.height, visibleFrame.height - margin * 2)
        let x = clamp(
            anchorMidX - width / 2,
            visibleFrame.minX + margin,
            visibleFrame.maxX - margin - width
        )
        let y = visibleFrame.maxY - margin - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}
