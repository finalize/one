import Foundation

// トラックパッドの端をなぞる判定（One/Trackpad/EdgeSlide.swift の EdgeSlideTracker）を確かめる。
//
// トラックパッドも音量も使わない。判定は「いま触れている指の位置」を1回ずつ受け取って段数を返すだけなので、
// 指の位置を自分で並べて流し込めば、指で触らずに全部試せる。
//
// 期待値は決めごと（端に触れ始めた指だけ・指1本だけ・なぞる向きに動き出したときだけ・押し込んでいないときだけ、
// 1段はなぞる向きの長さの 0.05、左右の端は幅の 0.10、上の端は高さの 0.06、どちらの向きかは 0.03 動いてから
// 決める、角では動き出した向きで決める）から手で数えた段数。
// 指の動きは 1回に 0.01 ずつ（実機でもおおむねこの細かさで届く）。境目ちょうどで終わると
// 小数の誤差で1段ずれうるので、なぞる距離は境目から外してある（0.27 なら 5 段）。

// MARK: - 組み立て

private typealias Change = EdgeSlideTracker.Change

/// 1回ぶんの入力。指の全部と、押し込んでいるか。
private struct Frame {
    var touches: [TrackpadTouch]
    var isPressing = false
    /// この回の前に、クリックなどでやめさせる（`interrupt()`）か。
    var interruptsFirst = false
    /// この回の前に、相手にする端を変える（設定を変えた）か。
    var setsEdges: Set<TrackpadEdge>?
}

/// フレームの列の `index` 番目に手を加える。
private func with(_ frames: [Frame], at index: Int, _ change: (inout Frame) -> Void) -> [Frame] {
    var frames = frames
    change(&frames[index])
    return frames
}

/// 指1本。`began` は「この回に触れ始めた」で、判定が見るのは見張りを始めて最初の回だけ。
/// 既定は true にして、ほかのテストでは気にしなくてよいようにしてある。
private func finger(_ id: Int, _ x: Double, _ y: Double, resting: Bool = false, began: Bool = true) -> TrackpadTouch {
    TrackpadTouch(id: AnyHashable(id), x: x, y: y, isResting: resting, began: began)
}

/// 指 `id` を (x0, y0) から (x1, y1) まで、1回に 0.01 ずつ動かす。最初の1回は触れた位置そのもの。
/// `others` は、その間ずっと触れている別の指。
private func slide(
    _ id: Int, from start: (Double, Double), to end: (Double, Double),
    others: [TrackpadTouch] = [], isPressing: Bool = false
) -> [Frame] {
    let distance = max(abs(end.0 - start.0), abs(end.1 - start.1))
    let count = max(1, Int((distance / 0.01).rounded()))
    return (0 ... count).map { i in
        let t = Double(i) / Double(count)
        let x = start.0 + (end.0 - start.0) * t
        let y = start.1 + (end.1 - start.1) * t
        return Frame(touches: [finger(id, x, y)] + others, isPressing: isPressing)
    }
}

/// 全部の指が離れた1回。
private let lift = Frame(touches: [])

// MARK: - 実行

@main
struct EdgeSlideTests {
    static var failures = 0

    /// 流したときに返った変化を、端ごとに足し合わせる。
    fileprivate static func run(
        _ frames: [Frame], edges: Set<TrackpadEdge> = [.left, .right, .top]
    ) -> (changes: [Change], volume: Int, brightness: Int, keyboard: Int) {
        var tracker = EdgeSlideTracker(edges: edges)
        var changes: [Change] = []
        for frame in frames {
            if let edges = frame.setsEdges { tracker.edges = edges }
            if frame.interruptsFirst { tracker.interrupt() }
            if let change = tracker.update(frame.touches, isPressing: frame.isPressing) {
                changes.append(change)
            }
        }
        let volume = changes.filter { $0.edge == .right }.reduce(0) { $0 + $1.steps }
        let brightness = changes.filter { $0.edge == .left }.reduce(0) { $0 + $1.steps }
        let keyboard = changes.filter { $0.edge == .top }.reduce(0) { $0 + $1.steps }
        return (changes, volume, brightness, keyboard)
    }

    /// 音量・画面の明るさ・キーボードの明るさが、それぞれ何段動いたかを見る。
    ///
    /// 合計だけでなく、動かないはずの端には変化が1つも出ていないことも見る（+1 と -1 で 0 になっても落とす）。
    fileprivate static func check(
        _ name: String, _ frames: [Frame], edges: Set<TrackpadEdge> = [.left, .right, .top],
        volume: Int = 0, brightness: Int = 0, keyboard: Int = 0
    ) {
        let result = run(frames, edges: edges)
        let expected: [TrackpadEdge: Int] = [.right: volume, .left: brightness, .top: keyboard]
        let untouchedOK = expected.allSatisfy { edge, steps in
            steps != 0 || !result.changes.contains { $0.edge == edge }
        }
        let ok = result.volume == volume && result.brightness == brightness && result.keyboard == keyboard
            && untouchedOK
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)  期待=音量\(volume) 明るさ\(brightness) キーボード\(keyboard)  実際=音量\(result.volume) 明るさ\(result.brightness) キーボード\(result.keyboard)")
    }

    static func main() {
        // MARK: 変わってほしいとき

        check("右の端を上へ 0.27 → 音量 +5", slide(1, from: (0.97, 0.30), to: (0.97, 0.57)), volume: 5)
        check("右の端を下へ 0.27 → 音量 -5", slide(1, from: (0.97, 0.70), to: (0.97, 0.43)), volume: -5)
        check("左の端を上へ 0.27 → 明るさ +5", slide(1, from: (0.03, 0.30), to: (0.03, 0.57)), brightness: 5)
        check("左の端を下へ 0.12 → 明るさ -2", slide(1, from: (0.03, 0.50), to: (0.03, 0.38)), brightness: -2)
        check("下から上まで 0.97 → 音量 +19", slide(1, from: (0.97, 0.01), to: (0.97, 0.98)), volume: 19)
        check("端の幅いっぱい（x = 0.905）で触れても右の端", slide(1, from: (0.905, 0.30), to: (0.905, 0.57)), volume: 5)
        check("端の幅いっぱい（x = 0.095）で触れても左の端", slide(1, from: (0.095, 0.30), to: (0.095, 0.57)), brightness: 5)
        check("斜め（縦 0.27 に横 0.12）でも、横が縦の半分より小さければ縦とみなす",
              slide(1, from: (0.97, 0.30), to: (0.85, 0.57)), volume: 5)
        check("なぞり始めたあとは、内側へずれても続く",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.40)) + slide(1, from: (0.97, 0.40), to: (0.60, 0.57)).dropFirst(),
              volume: 5)
        // 上へ 0.17 で +3（基準は 0.45 へ）。そこから 0.33 まで戻すと、基準から 0.12 下なので -2。
        check("上へ 0.17 から 0.14 戻す → +3 -2 で +1",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47)) + slide(1, from: (0.97, 0.47), to: (0.97, 0.33)).dropFirst(),
              volume: 1)
        check("親指を置いたまま（置いているだけの指）でも使える",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.57), others: [finger(9, 0.5, 0.05, resting: true)]),
              volume: 5)
        check("なぞっている指が途中で「置いているだけ」になっても続く",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + [Frame(touches: [finger(1, 0.97, 0.53, resting: true)])],
              volume: 4)

        // 1回で大きく動いたときは、まとめて返る
        let jump = run([Frame(touches: [finger(1, 0.97, 0.30)]), Frame(touches: [finger(1, 0.97, 0.42)])])
        let jumpOK = jump.changes == [Change(edge: .right, steps: 2)]
        if !jumpOK { failures += 1 }
        print("\(jumpOK ? "PASS" : "FAIL")  1回で 0.12 動いたら、まとめて +2 が1つ  実際=\(jump.changes.map(\.steps))")

        // MARK: 変わってはいけないとき

        check("真ん中で触れて縦に動かす", slide(1, from: (0.50, 0.30), to: (0.50, 0.57)))
        check("端のすぐ外（x = 0.12）で触れて縦に動かす", slide(1, from: (0.12, 0.30), to: (0.12, 0.57)))
        check("右の端のすぐ外（x = 0.88）で触れて縦に動かす", slide(1, from: (0.88, 0.30), to: (0.88, 0.57)))
        check("真ん中で触れて端まで滑らせ、そこから縦に動かす",
              slide(1, from: (0.50, 0.30), to: (0.97, 0.30)) + slide(1, from: (0.97, 0.30), to: (0.97, 0.57)).dropFirst())
        check("端で触れて先に内側へ動かし、そのあと縦に動かす",
              slide(1, from: (0.97, 0.30), to: (0.90, 0.30)) + slide(1, from: (0.90, 0.30), to: (0.90, 0.57)).dropFirst())
        check("端で触れて斜め 45 度に動かす", slide(1, from: (0.97, 0.30), to: (0.70, 0.57)))
        check("斜め（縦 0.27 に横 0.19）で、横が縦の半分より大きい", slide(1, from: (0.97, 0.30), to: (0.78, 0.57)))
        check("端に2本で触れて縦に動かす（スクロール）",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.57), others: [finger(2, 0.90, 0.30)]))
        check("真ん中に1本触れたまま、端をなぞる",
              [Frame(touches: [finger(2, 0.5, 0.5)])]
                  + slide(1, from: (0.97, 0.30), to: (0.97, 0.57), others: [finger(2, 0.5, 0.5)]))
        check("押し込んだまま端をなぞる（ドラッグ）", slide(1, from: (0.97, 0.30), to: (0.97, 0.57), isPressing: true))
        check("置いた指が少し揺れるだけ（0.02）", slide(1, from: (0.97, 0.30), to: (0.97, 0.32)) + [lift])
        check("1段に届かないまま離す（0.04）", slide(1, from: (0.97, 0.30), to: (0.97, 0.34)) + [lift])
        check("置いているだけの指が端で動いても数えない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.57)).map { frame in
                  Frame(touches: frame.touches.map { finger(1, $0.x, $0.y, resting: true) })
              })

        // MARK: 途中でやめる

        check("なぞっている途中で2本目が触れたら、そこでやめる",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + slide(1, from: (0.97, 0.47), to: (0.97, 0.77), others: [finger(2, 0.5, 0.5)]).dropFirst(),
              volume: 3)
        check("2本目が離れても、その回は戻らない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + [Frame(touches: [finger(1, 0.97, 0.47), finger(2, 0.5, 0.5)])]
                  + slide(1, from: (0.97, 0.47), to: (0.97, 0.77)).dropFirst(),
              volume: 3)
        check("なぞっている途中で押し込んだら、そこでやめる",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + slide(1, from: (0.97, 0.47), to: (0.97, 0.77), isPressing: true).dropFirst(),
              volume: 3)
        check("真ん中で触れた指が「置いているだけ」になり、端で戻って縦に動いても変わらない",
              [Frame(touches: [finger(1, 0.50, 0.30)]),
               Frame(touches: [finger(1, 0.50, 0.30, resting: true)]),
               Frame(touches: [finger(1, 0.97, 0.30, resting: true)])]
                  + slide(1, from: (0.97, 0.30), to: (0.97, 0.57)))
        check("なぞっていた指が離れ、端に置いていただけの指が残って動き出しても続けない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47), others: [finger(2, 0.95, 0.10, resting: true)])
                  + [Frame(touches: [finger(2, 0.95, 0.10, resting: true)])]
                  + slide(2, from: (0.95, 0.10), to: (0.95, 0.40)),
              volume: 3)
        check("なぞっている途中でクリックがあったら（interrupt）、そこでやめる",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + slide(1, from: (0.97, 0.47), to: (0.97, 0.77)).dropFirst().enumerated().map { i, frame in
                      var frame = frame
                      frame.interruptsFirst = i == 0
                      return frame
                  },
              volume: 3)
        check("指が触れていないときのクリックは、次になぞる回に響かない",
              [Frame(touches: [], interruptsFirst: true)] + slide(1, from: (0.97, 0.30), to: (0.97, 0.57)),
              volume: 5)
        check("なぞっていた指が離れて、同じ回に別の指が触れても続けない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + slide(2, from: (0.97, 0.47), to: (0.97, 0.77)),
              volume: 3)

        // MARK: 上の端と角

        check("上の端を右へ 0.27 → キーボード +5", slide(1, from: (0.30, 0.97), to: (0.57, 0.97)), keyboard: 5)
        check("上の端を左へ 0.12 → キーボード -2", slide(1, from: (0.60, 0.97), to: (0.48, 0.97)), keyboard: -2)
        check("上の端の幅いっぱい（y = 0.945）で触れても上の端", slide(1, from: (0.30, 0.945), to: (0.57, 0.945)), keyboard: 5)
        check("上の端のすぐ外（y = 0.93）で触れて横に動かす", slide(1, from: (0.30, 0.93), to: (0.57, 0.93)))
        check("上の端で触れて下へ動かす", slide(1, from: (0.50, 0.97), to: (0.50, 0.70)))
        check("上の端で触れて先に下へ動かし、そのあと横に動かす",
              slide(1, from: (0.50, 0.97), to: (0.50, 0.92)) + slide(1, from: (0.50, 0.92), to: (0.77, 0.92)).dropFirst())
        check("上の端で触れて斜め 45 度に動かす", slide(1, from: (0.30, 0.97), to: (0.57, 0.70)))
        check("上の端を2本でなぞる", slide(1, from: (0.30, 0.97), to: (0.57, 0.97), others: [finger(2, 0.40, 0.90)]))
        check("右上の角で触れて下へなぞる → 音量", slide(1, from: (0.97, 0.97), to: (0.97, 0.70)), volume: -5)
        check("右上の角で触れて左へなぞる → キーボード", slide(1, from: (0.97, 0.97), to: (0.70, 0.97)), keyboard: -5)
        check("左上の角で触れて右へなぞる → キーボード", slide(1, from: (0.03, 0.97), to: (0.30, 0.97)), keyboard: 5)
        check("左上の角で触れて斜めに動かす → どちらでもない", slide(1, from: (0.03, 0.97), to: (0.30, 0.70)))
        // 縦に 0.03 動いた時点で左右の端（音量）に決まる。そのあと横へ動かしても、キーボードは変わらない
        // （音量も、それ以上縦に動かないので変わらない）。
        check("右上の角で先に縦に 0.03 動いたら左右の端に決まり、そのあと横へ動かしてもキーボードは変わらない",
              slide(1, from: (0.97, 0.97), to: (0.97, 0.94)) + slide(1, from: (0.97, 0.94), to: (0.70, 0.94)).dropFirst())
        check("上の端を切ってあると、上の端をなぞっても変わらない",
              slide(1, from: (0.30, 0.97), to: (0.57, 0.97)), edges: [.left, .right])
        check("上の端を切ってあっても、角から下へなぞれば音量",
              slide(1, from: (0.97, 0.97), to: (0.97, 0.70)), edges: [.left, .right], volume: -5)
        check("上の端を切ってあると、角から横へなぞっても変わらない",
              slide(1, from: (0.97, 0.97), to: (0.70, 0.97)), edges: [.left, .right])
        check("左右の端を切ってあると、右の端をなぞっても変わらない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.57)), edges: [.top])
        check("左右の端を切ってあっても、角から横へなぞればキーボード",
              slide(1, from: (0.97, 0.97), to: (0.70, 0.97)), edges: [.top], keyboard: -5)

        // 横切る向き（縦）の揺れが 0.03 に届かないうちは、上の端の候補に残る。左右の端は横に 0.035 動いて外れる。
        check("左上の角で少し斜め（縦 0.022・横 0.035）に動き出してから横へなぞる → キーボード",
              [Frame(touches: [finger(1, 0.03, 0.97)]), Frame(touches: [finger(1, 0.065, 0.948)])]
                  + slide(1, from: (0.065, 0.948), to: (0.32, 0.948)).dropFirst(),
              keyboard: 5)

        // MARK: 途中で設定を変える

        check("角で決めかけている途中で上の端を切ったら、横へなぞってもキーボードは変わらない",
              with(slide(1, from: (0.97, 0.97), to: (0.70, 0.97)), at: 1) { $0.setsEdges = [.left, .right] })
        check("右の端をなぞっている途中で左右の端を切ったら、そこで止まる",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + with(Array(slide(1, from: (0.97, 0.47), to: (0.97, 0.77)).dropFirst()), at: 0) { $0.setsEdges = [.top] },
              volume: 3)
        check("同じ設定を入れ直しただけなら止まらない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47))
                  + with(Array(slide(1, from: (0.97, 0.47), to: (0.97, 0.57)).dropFirst()), at: 0) {
                      $0.setsEdges = [.left, .right, .top]
                  },
              volume: 5)

        // MARK: 見張りを始めたときに触れていた指

        let alreadyTouching = with(slide(1, from: (0.97, 0.30), to: (0.97, 0.57)), at: 0) {
            $0.touches = [finger(1, 0.97, 0.30, began: false)]
        }
        check("見張りを始めたときにもう端に触れていた指は、なぞっても変わらない", alreadyTouching)
        check("その指が離れたあとに触れ始めた指は、ふつうに効く",
              alreadyTouching + [lift] + slide(2, from: (0.97, 0.30), to: (0.97, 0.57)), volume: 5)

        // MARK: 行ったり来たりしない

        check("段の境目の上で指が揺れても、増えも減りもしない",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.36))
                  + slide(1, from: (0.97, 0.36), to: (0.97, 0.33)).dropFirst()
                  + slide(1, from: (0.97, 0.33), to: (0.97, 0.37)).dropFirst()
                  + slide(1, from: (0.97, 0.37), to: (0.97, 0.32)).dropFirst(),
              volume: 1)

        // MARK: 前の回を持ち越さない

        check("離してからもう一度なぞる",
              slide(1, from: (0.97, 0.30), to: (0.97, 0.47)) + [lift]
                  + slide(2, from: (0.03, 0.60), to: (0.03, 0.33)),
              volume: 3, brightness: -5)
        check("やめた回のあと、離してからなぞれば効く",
              slide(1, from: (0.50, 0.30), to: (0.50, 0.57)) + [lift]
                  + slide(2, from: (0.97, 0.30), to: (0.97, 0.57)),
              volume: 5)
        check("置いているだけの指だけが残っても、次の回は始められる",
              slide(1, from: (0.50, 0.30), to: (0.50, 0.57))
                  + [Frame(touches: [finger(9, 0.5, 0.05, resting: true)])]
                  + slide(2, from: (0.97, 0.30), to: (0.97, 0.57), others: [finger(9, 0.5, 0.05, resting: true)]),
              volume: 5)

        print(failures == 0 ? "\nすべて通過" : "\n\(failures) 件 失敗")
        exit(failures == 0 ? 0 : 1)
    }
}
