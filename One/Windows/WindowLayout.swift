import CoreGraphics

/// ウィンドウの操作。メニューとショートカットに1つずつ並ぶ。
///
/// 並びと既定のキーは Rectangle（https://rectangleapp.com/）に揃えてある。
/// 移行してきたときに指が迷わないように。
enum WindowAction: CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird
    case firstTwoThirds, centerTwoThirds, lastTwoThirds
    case maximize, maximizeHeight, center
    case larger, smaller
    case restore
    case previousDisplay, nextDisplay

    /// メニューに出す名前。
    ///
    /// 3分割は横長の画面では左・中央・右に分けるが、縦長の画面では上・中央・下に分ける
    /// （Rectangle と同じ）。名前は横長のほうに合わせてある。
    var title: String {
        switch self {
        case .leftHalf: "左半分"
        case .rightHalf: "右半分"
        case .topHalf: "上半分"
        case .bottomHalf: "下半分"
        case .topLeft: "左上"
        case .topRight: "右上"
        case .bottomLeft: "左下"
        case .bottomRight: "右下"
        case .firstThird: "左 1/3"
        case .centerThird: "中央 1/3"
        case .lastThird: "右 1/3"
        case .firstTwoThirds: "左 2/3"
        case .centerTwoThirds: "中央 2/3"
        case .lastTwoThirds: "右 2/3"
        case .maximize: "最大化"
        case .maximizeHeight: "高さだけ最大化"
        case .center: "中央へ"
        case .larger: "大きく"
        case .smaller: "小さく"
        case .restore: "元に戻す"
        case .previousDisplay: "前の画面へ"
        case .nextDisplay: "次の画面へ"
        }
    }
}

/// 画面1枚分の範囲。
///
/// **座標はすべて AX の座標系で持つ。** 主画面（メニューバーのある画面）の左上が原点で、
/// y は下に向かって増える。ウィンドウの位置を読み書きする Accessibility API がこの向きだから。
///
/// AppKit の `NSScreen` は逆で、左下が原点・y は上向き。両方を混ぜると上下が
/// 入れ替わる類いのバグになるので、`NSScreen` から受け取った直後に1回だけ変換して
/// （`init(cocoaFrame:cocoaVisibleFrame:primaryHeight:)`）、以降はこちらだけを使う。
struct ScreenArea: Equatable {
    /// 画面全体。ウィンドウがどの画面にあるかを決めるのに使う。
    var frame: CGRect
    /// メニューバーと Dock を除いた、ウィンドウを並べてよい範囲。
    var visible: CGRect

    init(frame: CGRect, visible: CGRect) {
        self.frame = frame
        self.visible = visible
    }

    /// AppKit の座標（左下原点・上向き）から作る。
    ///
    /// `primaryHeight` は主画面（`NSScreen.screens[0]`）の高さ。主画面の左下が AppKit の
    /// 原点で、左上が AX の原点なので、2つの原点はちょうど主画面の高さだけずれている。
    init(cocoaFrame: CGRect, cocoaVisibleFrame: CGRect, primaryHeight: CGFloat) {
        self.init(frame: cocoaFrame.flipped(primaryHeight: primaryHeight),
                  visible: cocoaVisibleFrame.flipped(primaryHeight: primaryHeight))
    }
}

extension CGRect {
    /// AppKit の座標と AX の座標を入れ替える。
    ///
    /// x と大きさはそのままで、上下だけがひっくり返る。同じ式で行きも帰りも変換できる
    /// （2回かけると元に戻る）。AX → AppKit は、スナップの枠（AppKit のウィンドウ）を
    /// 出すときに使う。
    func flipped(primaryHeight: CGFloat) -> CGRect {
        CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}

// MARK: - 移動先を決める

extension WindowAction {
    /// 移動先の枠を求める。動かしようが無いときは nil。
    ///
    /// nil になるのは3つだけ: 別の画面へ動かそうとしたが画面が1枚しか無い、
    /// 元に戻そうとしたが戻り先を覚えていない、これ以上小さくできない。
    ///
    /// 画面の状態もウィンドウの状態も引数で受け取り、Accessibility API にも
    /// NSScreen にも触らない。なので実際の画面が無くても全部の操作を試せる。
    ///
    /// - Parameters:
    ///   - window: いまのウィンドウの枠
    ///   - screens: つながっている画面すべて。先頭が主画面
    ///   - restore: 「元に戻す」の戻り先（One が最初に動かす前の枠）
    func target(for window: CGRect, screens: [ScreenArea], restore: CGRect?) -> CGRect? {
        guard let screen = ScreenArea.containing(window, in: screens) else { return nil }
        let area = screen.visible

        switch self {
        case .leftHalf: return Grid(cols: 2, x: 0..<1).rect(in: area)
        case .rightHalf: return Grid(cols: 2, x: 1..<2).rect(in: area)
        case .topHalf: return Grid(rows: 2, y: 0..<1).rect(in: area)
        case .bottomHalf: return Grid(rows: 2, y: 1..<2).rect(in: area)

        case .topLeft: return Grid(cols: 2, x: 0..<1, rows: 2, y: 0..<1).rect(in: area)
        case .topRight: return Grid(cols: 2, x: 1..<2, rows: 2, y: 0..<1).rect(in: area)
        case .bottomLeft: return Grid(cols: 2, x: 0..<1, rows: 2, y: 1..<2).rect(in: area)
        case .bottomRight: return Grid(cols: 2, x: 1..<2, rows: 2, y: 1..<2).rect(in: area)

        case .firstThird: return Grid.along(area, parts: 3, 0..<1).rect(in: area)
        case .centerThird: return Grid.along(area, parts: 3, 1..<2).rect(in: area)
        case .lastThird: return Grid.along(area, parts: 3, 2..<3).rect(in: area)
        case .firstTwoThirds: return Grid.along(area, parts: 3, 0..<2).rect(in: area)
        // 中央の 2/3 は、両側に 1/6 ずつ残す。6等分の 1〜4 マス目。
        case .centerTwoThirds: return Grid.along(area, parts: 6, 1..<5).rect(in: area)
        case .lastTwoThirds: return Grid.along(area, parts: 3, 1..<3).rect(in: area)

        case .maximize:
            return area
        case .maximizeHeight:
            return CGRect(x: window.minX, y: area.minY, width: window.width, height: area.height)
        case .center:
            return window.size.centered(in: area)

        case .larger:
            return resized(window, in: area, by: Self.sizeStep)
        case .smaller:
            let result = resized(window, in: area, by: -Self.sizeStep)
            // 小さくしすぎると元に戻すのが面倒になるので、画面の 1/4 で止める（Rectangle と同じ）。
            let tooSmall = result.width < (area.width * Self.minimumFraction).rounded(.down)
                || result.height < (area.height * Self.minimumFraction).rounded(.down)
            return tooSmall ? nil : result

        case .restore:
            return restore

        case .previousDisplay, .nextDisplay:
            let order = ScreenArea.ordered(screens)
            guard order.count > 1, let i = order.firstIndex(of: screen) else { return nil }
            let step = self == .nextDisplay ? 1 : -1
            let destination = order[(i + step + order.count) % order.count]
            return window.mapped(from: area, to: destination.visible)
        }
    }

    /// 大きく・小さくで、1回に変える幅（縦横それぞれ、両側の合計）。Rectangle の既定と同じ。
    static let sizeStep: CGFloat = 30
    /// 小さくするときの下限。画面の幅・高さに対する割合。
    static let minimumFraction: CGFloat = 0.25
    /// 画面の端に「付いている」とみなす距離。
    static let edgeTolerance: CGFloat = 5
}

// MARK: - 格子

/// 画面を縦横に等分した格子の、どのマスからどのマスまでを使うか。
///
/// 半分も 1/4 も 1/3 も 2/3 も、全部「等分した格子の何マス分か」で書ける。
/// Rectangle は操作ごとに別の計算を持っていて、端数の扱い（切り捨てるか、
/// 小数のまま残すか）が操作によって違う。そのせいで 1/3 を3つ並べると 1pt の
/// 隙間や重なりが出ることがある。ここでは境目の位置を1つの式で決めるので、
/// 隣り合う領域は必ず同じ境目を共有し、隙間も重なりも出ない。
struct Grid {
    var cols = 1
    var x = 0..<1
    var rows = 1
    var y = 0..<1

    /// 3分割のように「長いほうの辺に沿って」分けるもの。
    ///
    /// 横長の画面なら左右に、縦長の画面なら上下に分ける。縦長の画面で 1/3 を
    /// 縦に3本並べても細すぎて使えないから。正方形は縦長として扱う（Rectangle と同じ）。
    static func along(_ area: CGRect, parts: Int, _ range: Range<Int>) -> Grid {
        area.width > area.height
            ? Grid(cols: parts, x: range)
            : Grid(rows: parts, y: range)
    }

    func rect(in area: CGRect) -> CGRect {
        let left = Self.edge(x.lowerBound, of: cols, start: area.minX, length: area.width)
        let right = Self.edge(x.upperBound, of: cols, start: area.minX, length: area.width)
        let top = Self.edge(y.lowerBound, of: rows, start: area.minY, length: area.height)
        let bottom = Self.edge(y.upperBound, of: rows, start: area.minY, length: area.height)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// n 等分したときの i 本目の境目。端数は四捨五入して整数の位置に置く。
    ///
    /// 境目は i と n だけで決まるので、左の領域の右端と右の領域の左端は必ず一致する。
    static func edge(_ i: Int, of n: Int, start: CGFloat, length: CGFloat) -> CGFloat {
        start + (length * CGFloat(i) / CGFloat(n)).rounded()
    }
}

// MARK: - 画面の選び方

extension ScreenArea {
    /// ウィンドウがどの画面にあるか。
    ///
    /// 画面をまたいでいるときは、重なっている面積が一番大きい画面。どの画面とも
    /// 重なっていない（画面の外に追いやられた）ときは主画面、つまり配列の先頭。
    static func containing(_ window: CGRect, in screens: [ScreenArea]) -> ScreenArea? {
        var best: ScreenArea?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = window.intersection(screen.frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        return best ?? screens.first
    }

    /// 「次の画面」「前の画面」を決めるための並び。
    ///
    /// 上の段から下の段へ、同じ段の中では左から右へ（Rectangle の既定と同じ）。
    /// 片方がもう片方より完全に上にあれば上の段、縦に重なっていれば同じ段とみなす。
    static func ordered(_ screens: [ScreenArea]) -> [ScreenArea] {
        screens.sorted { a, b in
            if a.frame.maxY <= b.frame.minY { return true }
            if b.frame.maxY <= a.frame.minY { return false }
            return a.frame.minX < b.frame.minX
        }
    }
}

// MARK: - 大きく・小さく

/// 縦横それぞれを `delta` だけ大きく（負なら小さく）する。
///
/// 画面の端に付いている辺は端に付けたまま、反対側だけを動かす。左半分に置いた
/// ウィンドウを大きくすると、左端は動かずに右へ伸びる。Rectangle が「カーテン」と
/// 呼んでいる動き。どちらの端にも付いていなければ、両側へ半分ずつ伸び縮みする。
///
/// 縦か横の一方だけ画面いっぱい（左半分なら高さがいっぱい）のとき、小さくしても
/// その辺はいっぱいのまま残す。高さまで縮むと、並べたレイアウトが崩れるから。
/// 四辺すべてが画面の端に付いている（最大化している）ときだけ、縦横とも縮める。
private func resized(_ window: CGRect, in area: CGRect, by delta: CGFloat) -> CGRect {
    let fillsScreen = touches(window.minX, area.minX) && touches(window.maxX, area.maxX)
        && touches(window.minY, area.minY) && touches(window.maxY, area.maxY)
    let (x, width) = resizedSpan(start: window.minX, length: window.width,
                                 within: area.minX, area.width, by: delta, fillsScreen: fillsScreen)
    let (y, height) = resizedSpan(start: window.minY, length: window.height,
                                  within: area.minY, area.height, by: delta, fillsScreen: fillsScreen)
    return CGRect(x: x, y: y, width: width, height: height)
}

/// 1つの軸（横なら x と幅）について伸び縮みさせる。
private func resizedSpan(
    start: CGFloat, length: CGFloat,
    within areaStart: CGFloat, _ areaLength: CGFloat,
    by delta: CGFloat, fillsScreen: Bool
) -> (CGFloat, CGFloat) {
    let areaEnd = areaStart + areaLength
    let atStart = touches(start, areaStart)
    let atEnd = touches(start + length, areaEnd)
    let newLength = min(length + delta, areaLength)

    if atStart && atEnd {
        // 両端に付いている。大きくするならいっぱいのまま。小さくするなら、
        // 最大化しているときだけ両側から縮め、そうでなければいっぱいのまま。
        if delta > 0 || !fillsScreen { return (areaStart, areaLength) }
        return (start - (delta / 2).rounded(.down), newLength)
    }
    if atStart { return (areaStart, newLength) }
    if atEnd { return (areaEnd - newLength, newLength) }

    // どちらにも付いていない。両側へ半分ずつ。はみ出したら画面の中へ押し戻す。
    let newStart = start - (delta / 2).rounded(.down)
    return (min(max(newStart, areaStart), areaEnd - newLength), newLength)
}

private func touches(_ a: CGFloat, _ b: CGFloat) -> Bool {
    abs(a - b) <= WindowAction.edgeTolerance
}

// MARK: - 枠の小道具

extension CGSize {
    /// この大きさの枠を `area` の真ん中に置く。`area` より大きい辺は `area` に合わせて縮める。
    func centered(in area: CGRect) -> CGRect {
        let w = min(width, area.width)
        let h = min(height, area.height)
        return CGRect(
            x: area.minX + ((area.width - w) / 2).rounded(),
            y: area.minY + ((area.height - h) / 2).rounded(),
            width: w, height: h
        )
    }
}

extension CGRect {
    /// ある画面の中での位置と大きさを、割合のまま別の画面へ写す。
    ///
    /// 左半分にあったウィンドウは、大きさの違う画面へ移しても左半分に来る。
    /// 大きさではなく**四辺の位置**を写して丸めるので、隣り合って並んでいた
    /// ウィンドウは移したあとも隣り合ったまま（隙間も重なりも出ない）。
    ///
    /// 丸めるのは行き先の始点からの距離で、`Grid.edge` と同じ形にしてある。
    /// 座標そのものを丸めると、始点が負の画面で 0.5 ちょうどになったとき
    /// 逆向きに丸まり、格子の境目と 1pt ずれる。
    func mapped(from source: CGRect, to destination: CGRect) -> CGRect {
        func mapX(_ v: CGFloat) -> CGFloat {
            destination.minX + ((v - source.minX) / source.width * destination.width).rounded()
        }
        func mapY(_ v: CGFloat) -> CGFloat {
            destination.minY + ((v - source.minY) / source.height * destination.height).rounded()
        }
        let r = CGRect(x: mapX(minX), y: mapY(minY),
                       width: mapX(maxX) - mapX(minX), height: mapY(maxY) - mapY(minY))
        // 元の画面からはみ出していたウィンドウは、写した先でもはみ出すので中へ戻す。
        return r.nudged(into: destination)
    }

    /// 大きさを変えずに、`bounds` の中へ収まるように位置だけずらす。
    ///
    /// アプリには最小の大きさがあって、指示した大きさまで縮まないことがある。
    /// そのとき右端や下端が画面からはみ出すので、動かしたあとにこれで押し戻す。
    /// `bounds` より大きくて収まりきらないときは、左上を合わせる（タイトルバーと
    /// 閉じるボタンが画面の外に出ないように）。
    func nudged(into bounds: CGRect) -> CGRect {
        var r = self
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        return r
    }
}
