import CoreGraphics

/// 画面の端のどこへカーソルを持っていったか。
enum SnapEdge: CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
}

/// ドラッグで端へ寄せたときの行き先。どの画面の、どの端で、どう並べるか。
struct Snap: Equatable {
    let screen: ScreenArea
    let edge: SnapEdge
    let action: WindowAction

    /// 置く枠。スナップで使う操作は格子で決まるものだけなので、ウィンドウの今の位置には依らない。
    ///
    /// 画面をその1枚だけにして求める。ウィンドウがまだ別の画面に大きくかかっていても、
    /// カーソルを持っていった画面に置くため。
    var frame: CGRect? {
        action.target(for: screen.visible, screens: [screen], restore: nil)
    }
}

/// ドラッグで端へ寄せたときに、どこへ並べるかの決まり。
///
/// 配置は、それまで使っていた Rectangle の設定（`landscapeSnapAreas`）をそのまま移した。
/// 1/3 を中心にした配置で、Rectangle の既定とは違う。
///
/// ```
///  左上の角: 左半分    上の辺: 中央 1/3    右上の角: 右半分
///  左の辺:   左 1/3                        右の辺:   右 1/3
///  左下の角: 左下      下の辺: 3分割       右下の角: 右下
/// ```
///
/// 下の辺は、カーソルの位置で左・中央・右の 1/3 に分かれる。左（右）の 1/3 を
/// 出したまま下の辺に沿って中央へ滑らせると、左（右）の 2/3 になる。
enum SnapLayout {
    /// 端とみなす幅。画面の端からこれより近ければ辺。
    static let margin: CGFloat = 5
    /// 角とみなす広さ。縦横どちらの端からも `margin + cornerSize` より近ければ角。
    /// 角は辺よりずっと広く取ってある。辺は 5pt しかないので、角まで 5pt に絞ると狙えない。
    static let cornerSize: CGFloat = 20

    /// カーソルの位置から行き先を決める。端でなければ nil。
    ///
    /// - Parameters:
    ///   - point: カーソルの位置（AX の座標）
    ///   - screens: つながっている画面すべて
    ///   - prior: いま出している行き先の操作。下の辺で 2/3 に広げるかどうかに使う
    static func snap(at point: CGPoint, screens: [ScreenArea], prior: WindowAction?) -> Snap? {
        // 画面の境目の上は、右（下）の画面のものとする。`contains` は右端・下端を含まないので、
        // どの点もちょうど1枚の画面に属する。
        guard let screen = screens.first(where: { $0.frame.contains(point) }) else { return nil }
        // 縦長の画面の配置は決めていない（Rectangle でも横長とは別の設定で、使っていなかった）。
        // 横長の配置をそのまま当てると、1/3 が上下に分かれて「左の辺で上 1/3」のような
        // ちぐはぐなことになるので、縦長の画面ではスナップしない。
        //
        // 縦長かどうかは visible で見る。1/3 を縦に割るか横に割るかを決めているのが visible
        // だから（`Grid.along`）。frame で見ると、横に Dock を置いた正方形に近い画面で、
        // スナップはするのに 1/3 が上下に割れる、が起きうる。
        guard screen.visible.width > screen.visible.height else { return nil }
        // 端に来たかどうかは frame（画面全体）で見る。カーソルが届くのは画面の本当の端で、
        // メニューバーや Dock の上にも行けるから。
        guard let edge = edge(of: point, in: screen.frame) else { return nil }
        return Snap(screen: screen, edge: edge, action: action(for: edge, at: point, in: screen.visible, prior: prior))
    }

    /// カーソルが画面の端のどこにあるか。
    ///
    /// 角を先に見る。角の広さ（25pt）の中なら、辺の幅（5pt）より内側でも角になる。
    static func edge(of point: CGPoint, in frame: CGRect) -> SnapEdge? {
        let left = point.x - frame.minX
        let right = frame.maxX - point.x
        let top = point.y - frame.minY
        let bottom = frame.maxY - point.y
        let corner = margin + cornerSize

        switch (left < corner, right < corner, top < corner, bottom < corner) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if left < margin { return .left }
        if right < margin { return .right }
        if top < margin { return .top }
        if bottom < margin { return .bottom }
        return nil
    }

    /// 端ごとの操作。
    ///
    /// `area` は下の辺を3つに分ける範囲で、画面の visible を渡す。
    static func action(for edge: SnapEdge, at point: CGPoint, in area: CGRect, prior: WindowAction?) -> WindowAction {
        switch edge {
        case .topLeft: .leftHalf
        case .top: .centerThird
        case .topRight: .rightHalf
        case .left: .firstThird
        case .right: .lastThird
        case .bottomLeft: .bottomLeft
        case .bottom: bottomThirds(at: point.x, in: area, prior: prior)
        case .bottomRight: .bottomRight
        }
    }

    /// 下の辺の3分割。
    ///
    /// 境目は、1/3 に並べたウィンドウの境目と同じ位置（visible を `Grid.edge` で分けたもの）。
    /// カーソルのある区画と、出てくる枠の横の範囲が一致する。Dock を横に置いていても。
    ///
    /// 中央の区画は、左の 1/3 から滑ってきたなら左の 2/3、右の 1/3 から滑ってきたなら
    /// 右の 2/3、そうでなければ中央の 1/3（Rectangle と同じ）。
    private static func bottomThirds(at x: CGFloat, in area: CGRect, prior: WindowAction?) -> WindowAction {
        let first = Grid.edge(1, of: 3, start: area.minX, length: area.width)
        let second = Grid.edge(2, of: 3, start: area.minX, length: area.width)
        if x < first { return .firstThird }
        if x >= second { return .lastThird }
        switch prior {
        case .firstThird, .firstTwoThirds: return .firstTwoThirds
        case .lastThird, .lastTwoThirds: return .lastTwoThirds
        default: return .centerThird
        }
    }
}

// MARK: - スナップを外す

extension CGRect {
    /// スナップしていたウィンドウをドラッグで引き剥がしたときの枠。大きさだけ元に戻す。
    ///
    /// 左上はそのまま（タイトルバーはカーソルの下に残る）。ただ、幅が狭くなると
    /// 掴んでいた場所がウィンドウの外に出てしまうことがある。そのときは、カーソルが
    /// 右端から 32pt 内側に来るまでウィンドウを右へずらす。ずらすのは、元の枠の
    /// 右端を越えない範囲まで（Rectangle と同じ）。
    ///
    /// - Parameters:
    ///   - size: 戻す大きさ（スナップする前の大きさ）
    ///   - cursor: いまのカーソルの位置
    func unsnapped(to size: CGSize, cursor: CGPoint) -> CGRect {
        var result = CGRect(origin: origin, size: size)
        let inset = min(32, size.width / 2)
        let needed = cursor.x - minX - (size.width - inset)
        result.origin.x += min(max(0, needed), max(0, width - size.width))
        return result
    }
}

// MARK: - 1回のドラッグを追う

/// 1回のドラッグで、ウィンドウを動かしているのか、どこへスナップしそうかを追う。
///
/// `CommandKeyWatcher` と同じ考え方で、イベントの解釈だけを持ち、画面にもウィンドウにも
/// 触らない。何をすべきかを `Effect` で返し、実際に行うのは `DragSnapper`。
/// こうしておくと、マウスを使わずに、押す・動かす・離すを並べて試せる。
///
/// マウスのドラッグは、ウィンドウを動かすとき以外にも起きる（文字の選択、ファイルの
/// ドラッグ、ウィンドウの端を掴んで大きさを変える）。それらを見分けるために、押した
/// ウィンドウの枠を見て「大きさが変わらずに位置だけ変わった」ときだけを移動とみなす。
struct SnapTracker {
    /// 外で行うこと。
    enum Effect: Equatable {
        /// ウィンドウを動かし始めた。One がスナップしていたウィンドウなら、元の大きさに戻す合図。
        case began(initial: CGRect, current: CGRect)
        /// 行き先の枠を見せる。
        case preview(Snap)
        /// 見せていた枠を消す。
        case hidePreview
        /// 離したので置く。元に戻す先の基準は `initial`（ドラッグを始める前の枠）。
        case place(Snap, initial: CGRect)
    }

    private enum State: Equatable {
        /// マウスを押していない。
        case idle
        /// ウィンドウの上で押した。まだ動かしているかどうか分からない。
        /// `last` はその間の直前の drag の位置（まだ無ければ nil）。
        case pressed(at: CGPoint, initial: CGRect, last: CGPoint?)
        /// ウィンドウを動かしている。`shown` はいま見せている行き先。
        case moving(initial: CGRect, shown: Snap?)
        /// このドラッグは相手にしない（ウィンドウの外で押した、大きさを変えている、Esc で取り消した等）。
        case ignored
    }

    private var state = State.idle

    /// ウィンドウが動かないまま、カーソルが押した位置からこれだけ離れたら、
    /// ウィンドウのドラッグではないとみなして見るのをやめる。
    ///
    /// 見分けるにはドラッグのたびにウィンドウの枠を読む（ウィンドウサーバーへの問い合わせ）
    /// 必要がある。文字を選択しているあいだ中それを続けないための打ち切り。
    /// ウィンドウを掴んで動かせば、ここまで離れるずっと前に枠が動く。
    ///
    /// ただし、読める枠はイベント1つ分遅れて動く（ウィンドウサーバーがそのイベントで
    /// ウィンドウを動かす前に、One が読むことがある）。なので見切るのは、**1つ前の** drag の
    /// 時点でここまで離れていたのに、まだ動いていないとき。最初の1歩が大きい速いドラッグでも、
    /// 1歩目で見切らない。
    static let giveUpDistance: CGFloat = 50

    /// マウスを押した。`window` は押した場所にあるウィンドウの枠（無ければ nil）。
    mutating func press(at point: CGPoint, window: CGRect?) {
        state = window.map { .pressed(at: point, initial: $0, last: nil) } ?? .ignored
    }

    /// 押したまま動かした。
    ///
    /// ウィンドウの枠は、動かしているかどうか分からないうちだけ要る。読むのに
    /// 相手のアプリへの問い合わせが要るので、値ではなく関数で受け取り、要るときだけ呼ぶ。
    mutating func drag(to point: CGPoint, screens: [ScreenArea], window: () -> CGRect?) -> [Effect] {
        switch state {
        case .idle, .ignored:
            return []
        case let .pressed(pressedAt, initial, last):
            guard let current = window() else {
                state = .ignored
                return []
            }
            if current.size != initial.size {
                // 端を掴んで大きさを変えている。
                state = .ignored
                return []
            }
            if current.origin == initial.origin {
                // まだ動いていない。1つ前の drag の時点で遠くまで来ていたなら、その分はもう
                // 動いているはずなので、ウィンドウのドラッグではない。
                if let last, hypot(last.x - pressedAt.x, last.y - pressedAt.y) > Self.giveUpDistance {
                    state = .ignored
                } else {
                    state = .pressed(at: pressedAt, initial: initial, last: point)
                }
                return []
            }
            state = .moving(initial: initial, shown: nil)
            return [.began(initial: initial, current: current)] + follow(point, screens)
        case .moving:
            return follow(point, screens)
        }
    }

    /// 離した。行き先の上で離したなら置く。
    mutating func release(at point: CGPoint, screens: [ScreenArea]) -> [Effect] {
        defer { state = .idle }
        guard case let .moving(initial, shown) = state else { return [] }
        var effects: [Effect] = shown == nil ? [] : [.hidePreview]
        // 最後のドラッグから離すまでの間にもカーソルは動くので、離した位置で決め直す。
        if let snap = SnapLayout.snap(at: point, screens: screens, prior: shown?.action) {
            effects.append(.place(snap, initial: initial))
        }
        return effects
    }

    /// Esc を押した。このドラッグではスナップしない。
    mutating func cancel() -> [Effect] {
        guard case let .moving(_, shown) = state else { return [] }
        state = .ignored
        return shown == nil ? [] : [.hidePreview]
    }

    /// 動かしている最中に、行き先が変わったら見せ直す。同じなら何もしない。
    private mutating func follow(_ point: CGPoint, _ screens: [ScreenArea]) -> [Effect] {
        guard case let .moving(initial, shown) = state else { return [] }
        let snap = SnapLayout.snap(at: point, screens: screens, prior: shown?.action)
        guard snap != shown else { return [] }
        state = .moving(initial: initial, shown: snap)
        return [snap.map(Effect.preview) ?? .hidePreview]
    }
}
