import Foundation

/// トラックパッドのどちらの端か。右の端で音量、左の端でキーボードの明るさを変える。
enum TrackpadEdge {
    case left
    case right
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

/// 端をなぞる1回を解釈する。指の位置を受け取るたびに、どちらの端で何段動かすかを返す。
///
/// `SnapTracker` と同じ形で、イベントにも音量にも触らない。見張る側（`EdgeSlideWatcher`）が
/// 指の位置を渡し、返ってきた段数だけキーを送る。
///
/// ふつうにポインタを動かすつもりの指を取り違えないように、次の順で絞る。
///
/// 1. **端に触れ始めた指だけ。** 真ん中で触れて端へ滑ってきた指は相手にしない。前から触れていた指
///    （「置いているだけ」だった指を含む）が端で動き出しても、触れ始めとはみなさない
/// 2. **指が1本のときだけ。** 2本目が触れたら（スクロールなど）その回はやめる
/// 3. **縦に動き出したときだけ。** 端から内側へ動き出したら、ポインタを動かしたいのだと見て、やめる
/// 4. **クリックしていないときだけ。** 押し込んだままの指は、ドラッグをしている。途中でクリックしたら
///    （`interrupt()`）、その回はやめる
///
/// やめた回は、全部の指が離れるまで何もしない。途中から音量が変わり出すことは無い。
struct EdgeSlideTracker {
    /// 1回に返す変化。
    struct Change: Equatable {
        let edge: TrackpadEdge
        /// 上へなぞれば正、下へなぞれば負。1段は、キーを1回押した分。
        let steps: Int
    }

    /// 端とみなす幅。トラックパッドの幅に対する割合。
    ///
    /// 広いほど当てやすく、ふつうにポインタを動かす指を取り違えやすい。Magic Trackpad の右の端を
    /// なぞってもらうと、指の中心は 0.91〜1.0 にあった。0.08 では 0.913 で触れた1回を取りこぼした。
    static let edgeWidth = 0.10
    /// 縦か横かを決めるまでに待つ距離。トラックパッドの高さ（横は幅）に対する割合。
    ///
    /// 置いた瞬間の指は、どちらへともなく少し揺れる。そこで決めてしまわないように、ここまで待つ。
    static let decideDistance = 0.03
    /// 1段ぶんの距離。トラックパッドの高さに対する割合。
    ///
    /// 音量もキーボードの明るさもキーで 16 段なので、下から上まで（20 段）なぞればいちばん下から
    /// いちばん上まで変わる。
    static let stepHeight = 0.05

    private enum State {
        /// 指が触れていない。次に触れた指を見る。
        case idle
        /// 端に触れたが、縦になぞるのか、ポインタを動かすのか、まだ分からない。触れた位置を持つ。
        case deciding(id: AnyHashable, edge: TrackpadEdge, x: Double, y: Double)
        /// 縦になぞっている。`anchor` は、最後に段を動かした高さ。
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

    /// 指の位置を1回ぶん受け取る。音量・キーボードの明るさを動かすときだけ値を返す。
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
        case let .deciding(id, _, _, _), let .sliding(id, _, _): id
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
            if touch.x <= Self.edgeWidth {
                state = .deciding(id: touch.id, edge: .left, x: touch.x, y: touch.y)
            } else if touch.x >= 1 - Self.edgeWidth {
                state = .deciding(id: touch.id, edge: .right, x: touch.x, y: touch.y)
            } else {
                state = .ignoring
            }
            return nil

        case let .deciding(id, edge, x, y):
            guard let touch = sole(active, id: id, isPressing: isPressing) else { return nil }
            let dx = abs(touch.x - x)
            let dy = abs(touch.y - y)
            // はっきり縦（横の倍以上）に動いたら、なぞり始めた。触れた高さから段を数える。
            if dy >= Self.decideDistance && dy >= dx * 2 {
                state = .sliding(id: id, edge: edge, anchor: y)
                return advance(touch, id: id, edge: edge, anchor: y)
            }
            // 先に横へ動いたら、ポインタを動かしている。
            if dx >= Self.decideDistance {
                state = .ignoring
            }
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
    /// 段を動かした高さを新しい基準にするので、境目の上で指が細かく揺れても、行ったり来たりしない。
    /// 下へ1段戻すには、そこからさらに1段ぶん下ろす必要がある。
    private mutating func advance(_ touch: TrackpadTouch, id: AnyHashable, edge: TrackpadEdge, anchor: Double) -> Change? {
        // Int(...) は 0 の側へ切り捨てる。-1.4 段なら -1 段で、残りの -0.4 は次へ持ち越す。
        let steps = Int((touch.y - anchor) / Self.stepHeight)
        guard steps != 0 else { return nil }
        state = .sliding(id: id, edge: edge, anchor: anchor + Double(steps) * Self.stepHeight)
        return Change(edge: edge, steps: steps)
    }
}
