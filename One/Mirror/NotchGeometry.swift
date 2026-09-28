import CoreGraphics

/// ノッチがどこにあるかの計算。
///
/// AppKit を import しない。`NSScreen` から取り出した数字だけを受け取るので、
/// ノッチの無いこの Mac でもテストで確かめられる。
enum NotchGeometry {
    /// ノッチの矩形を返す。ノッチが無い画面なら nil。
    ///
    /// 座標は `NSScreen.frame` と同じ、全画面を通した左下原点のもの。
    ///
    /// - screenFrame: `NSScreen.frame`
    /// - topInset: `NSScreen.safeAreaInsets.top`。ノッチのある画面だけ 0 より大きい
    /// - leftWidth / rightWidth: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` の幅。
    ///   ノッチの左右に残った、メニューバーとして使える部分
    ///
    /// 左右の領域は幅だけを使い、位置（origin）は使わない。origin が画面ローカルなのか
    /// 全画面を通した座標なのかに頼らずに済むからだ。画面の左端から左側の幅ぶん進んだ所から、
    /// 右端から右側の幅ぶん戻った所までがノッチになる。
    static func notchRect(
        screenFrame: CGRect,
        topInset: CGFloat,
        leftWidth: CGFloat?,
        rightWidth: CGFloat?
    ) -> CGRect? {
        guard topInset > 0, let leftWidth, let rightWidth else { return nil }
        let minX = screenFrame.minX + leftWidth
        let maxX = screenFrame.maxX - rightWidth
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: screenFrame.maxY - topInset, width: maxX - minX, height: topInset)
    }

    /// ノッチの無い画面で試すための、上端中央の偽のノッチ。
    ///
    /// 本物のノッチ（14 インチで幅 200pt 前後）と同じくらいの大きさにしてある。
    static func fakeNotchRect(screenFrame: CGRect, height: CGFloat, width: CGFloat = 200) -> CGRect {
        CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }
}
