import Foundation

/// トラックパッドのどの端か。左の端で画面の明るさ、右の端で音量、上の端でキーボードの明るさを変える。
enum TrackpadEdge {
    case left
    case right
    case top
}

/// トラックパッドに触れている指1本分。`NSTouch` から、判定に要るところだけを写したもの。
///
/// `NSTouch` は自分では作れない（公開された初期化が無い）。判定はこの型で受け取るようにして、
/// トラックパッド無しで、指の位置を並べて渡せば試せるようにしてある。
struct TrackpadTouch {
    /// 同じ指なら、触れている間ずっと同じ値。`NSTouch.identity` を入れる。
    /// 中身は比べられさえすればよいので、何の型かは問わない（`AnyHashable`）。
    let id: AnyHashable
    /// トラックパッドの上の位置。幅と高さをそれぞれ 0〜1 にしたもの。原点は左下で、y は上向き
    /// （`NSTouch.normalizedPosition` と同じ）。
    let x: Double
    let y: Double
    /// macOS が「置いているだけ」と見た指。打鍵中に載せた親指や、手のひらなど。
    let isResting: Bool
    /// この回に触れ始めた指か（`NSTouch.phase` が `.began`）。見張りを始めて最初の回だけ使う。
    var began = false
}

/// 端をなぞる1回を解釈する。指の位置を受け取るたびに、どの端で何段動かすかを返す。
///
/// `SnapTracker` と同じ形で、イベントにも音量にも触らない。見張る側（`EdgeSlideWatcher`）が
/// 指の位置を渡し、返ってきた段数だけキーを送る。
///
/// 左右の端は縦に、上の端は横になぞる。端に沿う向きを「なぞる向き」、端から離れる向きを
/// 「横切る向き」と呼ぶ（左右の端なら縦がなぞる向き、上の端なら横がなぞる向き）。
///
/// ふつうにポインタを動かすつもりの指を取り違えないように、次の順で絞る。
///
/// 1. **端に触れ始めた指だけ。** 真ん中で触れて端へ滑ってきた指は相手にしない。前から触れていた指
///    （「置いているだけ」だった指を含む）が端で動き出しても、触れ始めとはみなさない
/// 2. **指が1本のときだけ。** 2本目が触れたら（スクロールなど）その回はやめる
/// 3. **なぞる向きに動き出したときだけ。** 横切る向きに先に動いたら、ポインタを動かしたいのだと見て、やめる
/// 4. **クリックしていないときだけ。** 押し込んだままの指は、ドラッグをしている。途中でクリックしたら
///    （`interrupt()`）、その回はやめる
///
/// 左上と右上の角は、左右の端でもあり上の端でもある。ここで触れた指は、縦に動き出せば左右の端、
/// 横に動き出せば上の端になる。どちらの端も、横切る向きに `decideDistance` 動いた時点で候補から外れる
/// （上の端なら縦に、左右の端なら横に）。45 度に近い斜めで両方とも外れたら、どちらでもない。横切る向きの
/// 揺れがそれより小さいうちは候補に残るので、少し斜めに動き出してから端に沿って動かせば、その端になる。
///
/// やめた回は、全部の指が離れるまで何もしない。途中から音量が変わり出すことは無い。
struct EdgeSlideTracker {
    /// 1回に返す変化。
    struct Change: Equatable {
        let edge: TrackpadEdge
        /// 左右の端は上へ、上の端は右へなぞれば正。逆なら負。1段は、キーを1回押した分。
        let steps: Int
    }

    /// 左右の端とみなす幅。トラックパッドの幅に対する割合。
    ///
    /// 広いほど当てやすく、ふつうにポインタを動かす指を取り違えやすい。Magic Trackpad の右の端を
    /// なぞってもらうと、指の中心は 0.91〜1.0 にあった。0.08 では 0.913 で触れた1回を取りこぼした。
    static let sideEdgeWidth = 0.10
    /// 上の端とみなす幅。トラックパッドの高さに対する割合。
    ///
    /// 左右より狭くしてある。キーボードから手を下ろして、トラックパッドの上のほうで横にポインタを
    /// 動かすのはよくある動きで、左右の端を縦に動かすより取り違えやすいから。
    static let topEdgeWidth = 0.06
    /// なぞる向きか横切る向きかを決めるまでに待つ距離。その向きの長さ（縦なら高さ、横なら幅）に対する割合。
    ///
    /// 置いた瞬間の指は、どちらへともなく少し揺れる。そこで決めてしまわないように、ここまで待つ。
    static let decideDistance = 0.03
    /// 1段ぶんの距離。なぞる向きの長さに対する割合。
    ///
    /// 音量も明るさもキーで 16 段なので、端から端まで（20 段）なぞればいちばん下からいちばん上まで変わる。
    static let stepLength = 0.05

    /// 相手にする端。設定で切った端は入れない。
    ///
    /// 変わったら、決めかけている回・なぞっている回はやめる。切った端のまま続けないように。
    var edges: Set<TrackpadEdge> {
        didSet {
            if edges != oldValue { interrupt() }
        }
    }

    private enum State {
        /// 指が触れていない。次に触れた指を見る。
        case idle
        /// 端に触れたが、なぞるのか、ポインタを動かすのか、まだ分からない。触れた位置を持つ。
        /// `side` は触れた左右の端（無ければ nil）、`top` は上の端にも触れたか。
        /// 角で触れたときは両方が入っていて、動き出した向きで片方に決まる。
        case deciding(id: AnyHashable, side: TrackpadEdge?, top: Bool, x: Double, y: Double)
        /// なぞっている。`anchor` は、最後に段を動かした位置（左右の端なら y、上の端なら x）。
        case sliding(id: AnyHashable, edge: TrackpadEdge, anchor: Double)
        /// この回は相手にしない。全部の指が離れるまで待つ。
        case ignoring
    }

    private var state = State.idle
    /// 前の回に触れていた指（置いているだけの指を含む）。
    ///
    /// 置いているだけの指は数えないので、それしか残っていなければ「指が触れていない」に戻る。そのあと
    /// その指が置いているだけでなくなっても、新しく触れた指とは見分けたい。でないと、真ん中で触れて
    /// 置いたまま端へずれた指や、端に置いていた指で、途中から音量が変わり出す。
    private var present: Set<AnyHashable> = []
    /// 指の位置を一度でも受け取ったか。
    ///
    /// 受け取る前は `present` が空なので、見張りを始めたときにもう触れていた指も、触れ始めた指に見えてしまう。
    /// 最初の回だけは、`TrackpadTouch.began`（macOS が教える「この回に触れ始めた」）で見分ける。
    private var hasSeenTouches = false

    init(edges: Set<TrackpadEdge> = [.left, .right, .top]) {
        self.edges = edges
    }

    /// 指の位置を1回ぶん受け取る。音量・明るさを動かすときだけ値を返す。
    ///
    /// - Parameters:
    ///   - touches: いま触れている指の全部。離れた指は入れない。
    ///   - isPressing: マウスのボタン（トラックパッドの押し込みを含む）が押されているか。
    mutating func update(_ touches: [TrackpadTouch], isPressing: Bool) -> Change? {
        let wasPresent = present
        let isFirst = !hasSeenTouches
        // defer の中身は、この関数を抜けるときに走る。どの return で抜けても次の回のために残す。
        defer {
            present = Set(touches.map(\.id))
            hasSeenTouches = true
        }

        // 置いているだけの指は数えない。打鍵中に親指を載せたままでも使えるように。
        // ただし追っている指は、途中で「置いているだけ」と見なされても追い続ける。
        let tracked: AnyHashable? = switch state {
        case let .deciding(id, _, _, _, _), let .sliding(id, _, _): id
        case .idle, .ignoring: nil
        }
        let active = touches.filter { !$0.isResting || $0.id == tracked }

        guard !active.isEmpty else {
            state = .idle
            return nil
        }

        switch state {
        case .idle:
            // 数える指が無いところへ来た指。いま触れ始めた指で、端に触れたときだけ見る。
            guard active.count == 1, !isPressing, let touch = active.first, !wasPresent.contains(touch.id),
                  !isFirst || touch.began else {
                state = .ignoring
                return nil
            }
            var side: TrackpadEdge?
            if touch.x <= Self.sideEdgeWidth {
                side = .left
            } else if touch.x >= 1 - Self.sideEdgeWidth {
                side = .right
            }
            if let edge = side, !edges.contains(edge) {
                side = nil
            }
            let top = touch.y >= 1 - Self.topEdgeWidth && edges.contains(.top)
            state = side != nil || top
                ? .deciding(id: touch.id, side: side, top: top, x: touch.x, y: touch.y)
                : .ignoring
            return nil

        case .deciding(let id, var side, var top, let x, let y):
            guard let touch = sole(active, id: id, isPressing: isPressing) else { return nil }
            let dx = abs(touch.x - x)
            let dy = abs(touch.y - y)
            // はっきりなぞる向き（横切る向きの倍以上）に動いたら、なぞり始めた。触れた位置から段を数える。
            if let edge = side, dy >= Self.decideDistance && dy >= dx * 2 {
                state = .sliding(id: id, edge: edge, anchor: y)
                return advance(touch, id: id, edge: edge, anchor: y)
            }
            if top, dx >= Self.decideDistance && dx >= dy * 2 {
                state = .sliding(id: id, edge: .top, anchor: x)
                return advance(touch, id: id, edge: .top, anchor: x)
            }
            // 先に横切る向きへ動いたら、その端ではない。左右の端は横に、上の端は縦に動いたら外れる。
            if dx >= Self.decideDistance { side = nil }
            if dy >= Self.decideDistance { top = false }
            state = side != nil || top
                ? .deciding(id: id, side: side, top: top, x: x, y: y)
                : .ignoring
            return nil

        case let .sliding(id, edge, anchor):
            guard let touch = sole(active, id: id, isPressing: isPressing) else { return nil }
            return advance(touch, id: id, edge: edge, anchor: anchor)

        case .ignoring:
            return nil
        }
    }

    /// この回をやめる。なぞっている途中でクリックがあったときなどに呼ぶ。
    ///
    /// 指の位置と別の道で知らされることなので、位置を渡す `update` とは分けてある。
    /// 指が触れていないときは何もしない（次に触れた指は、ふつうに見る）。
    mutating func interrupt() {
        switch state {
        case .deciding, .sliding: state = .ignoring
        case .idle, .ignoring: break
        }
    }

    /// 追っている指が、ただ1本触れている指のままならそれを返す。そうでなければこの回をやめる。
    ///
    /// 2本目が触れた、追っている指が離れた、押し込んだ、のどれかでやめる。
    private mutating func sole(_ active: [TrackpadTouch], id: AnyHashable, isPressing: Bool) -> TrackpadTouch? {
        guard active.count == 1, !isPressing, let touch = active.first, touch.id == id else {
            state = .ignoring
            return nil
        }
        return touch
    }

    /// `anchor` から1段ぶん以上動いていたら、その段数を返して `anchor` を進める。
    ///
    /// 段を動かした位置を新しい基準にするので、境目の上で指が細かく揺れても、行ったり来たりしない。
    /// 1段戻すには、そこからさらに1段ぶん戻す必要がある。
    private mutating func advance(_ touch: TrackpadTouch, id: AnyHashable, edge: TrackpadEdge, anchor: Double) -> Change? {
        let position = edge == .top ? touch.x : touch.y
        // Int(...) は 0 の側へ切り捨てる。-1.4 段なら -1 段で、残りの -0.4 は次へ持ち越す。
        let steps = Int((position - anchor) / Self.stepLength)
        guard steps != 0 else { return nil }
        state = .sliding(id: id, edge: edge, anchor: anchor + Double(steps) * Self.stepLength)
        return Change(edge: edge, steps: steps)
    }
}
