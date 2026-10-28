import CoreGraphics
import Foundation

// ドラッグでのスナップの判断（One/SnapLayout.swift）と、それが使う座標の入れ替え（flipped）・
// 元に戻す先（WindowHistory.restoreFrame(for:ifStillAt:)）を確かめる。
//
// 画面もウィンドウもマウスも使わない。端の判定と行き先は点と画面の枠（ScreenArea）だけで決まり、
// 1回のドラッグの追跡（SnapTracker）は、押す・動かす・離す・Esc を渡すと外で行うことの列を返すだけなので、
// 画面を自分で組み立て、ウィンドウの枠を返す関数を偽物（呼ばれた回数を数える）にすれば、全部を1プロセスで試せる。
//
// 実装は読まずに、仕様（「One のドラッグでのスナップ — 決めごと」）だけを見て書いた。
// 期待値は仕様の例の数値か、仕様の規則から手で計算した値。実装の出力を写した値は無い。
// 置く枠（leftHalf などの格子）は、前の仕様の境目の式 s + round(L × k / n) で手で計算した。

// MARK: - 組み立て

private typealias Effect = SnapTracker.Effect

private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

// 仕様の例の主画面（上にメニューバー 30、下に Dock 64）。
private let mainScreen = ScreenArea(frame: box(0, 0, 2560, 1440), visible: box(0, 30, 2560, 1346))
// 主画面の右隣。高さが低いので、主画面の右下の外（x ≥ 2560, y ≥ 1080）はどの画面でもない。
private let rightScreen = ScreenArea(frame: box(2560, 0, 1920, 1080), visible: box(2560, 25, 1920, 1055))
// 主画面の左。x がすべて負。下へずらしてある。右の辺（x = 0）は主画面の左の辺に接している。
private let leftScreen = ScreenArea(frame: box(-1920, 360, 1920, 1080), visible: box(-1920, 385, 1920, 1055))
// 主画面の上。y がすべて負。下の辺（y = 0）は主画面の上の辺に接している。
private let upperScreen = ScreenArea(frame: box(1500, -1080, 1920, 1080), visible: box(1500, -1055, 1920, 1055))
/// 互いに重ならない4枚。
private let allScreens = [mainScreen, rightScreen, leftScreen, upperScreen]

// 主画面の右に縦置きした画面（幅 < 高さ）。
private let portraitScreen = ScreenArea(frame: box(2560, -400, 1080, 1920), visible: box(2560, -375, 1080, 1895))
// frame が正方形。visible はメニューバーの分だけ低いので横長だが、仕様は frame で見る。
private let squareScreen = ScreenArea(frame: box(-1000, 0, 1000, 1000), visible: box(-1000, 25, 1000, 975))
// 幅が高さより 1 だけ大きい画面。
private let barelyWideScreen = ScreenArea(frame: box(-1001, 0, 1001, 1000), visible: box(-1001, 25, 1001, 975))
// 負の x にある奇数幅の画面。幅 1001 の 1/3 は 333.67 で、四捨五入（334）と切り捨て（333）で境目が違う。
private let oddScreen = ScreenArea(frame: box(-1001, 0, 1001, 800), visible: box(-1001, 25, 1001, 775))
// Dock を左に置いた画面。visible の横が frame より狭い。
private let dockLeftScreen = ScreenArea(frame: box(0, 0, 2560, 1440), visible: box(80, 25, 2480, 1415))

private func snapOn(_ screen: ScreenArea, _ edge: SnapEdge, _ action: WindowAction) -> Snap {
    Snap(screen: screen, edge: edge, action: action)
}

private func snap(_ p: CGPoint, _ screens: [ScreenArea] = [mainScreen], prior: WindowAction? = nil) -> Snap? {
    SnapLayout.snap(at: p, screens: screens, prior: prior)
}

// MARK: - 仕様の式（期待値を作るためのもの）

/// 前の仕様の境目の式: 始点 s・長さ L を n 等分した k 本目の境目 = s + round(L × k / n)。
private func specBorder(_ s: CGFloat, _ length: CGFloat, _ k: Int, _ n: Int) -> CGFloat {
    s + (length * CGFloat(k) / CGFloat(n)).rounded()
}

/// 端ごとの操作の表（仕様の表をそのまま写したもの）。下の辺は3分割なので別に確かめる。
/// 点はその端に当たる主画面の点。
private let edgeActionTable: [(SnapEdge, CGPoint, WindowAction)] = [
    (.topLeft, pt(10, 10), .leftHalf),
    (.top, pt(1280, 2), .maximize),
    (.topRight, pt(2550, 10), .rightHalf),
    (.left, pt(2, 700), .firstThird),
    (.right, pt(2558, 700), .lastThird),
    (.bottomLeft, pt(10, 1430), .bottomLeft),
    (.bottomRight, pt(2550, 1430), .bottomRight),
]

/// 下の辺の中央で、いま見せている行き先（prior）→ 操作。表に無い prior はすべて centerThird。
private let middlePriorTable: [(WindowAction?, WindowAction)] = [
    (nil, .centerThird),
    (.firstThird, .firstTwoThirds), (.firstTwoThirds, .firstTwoThirds),
    (.lastThird, .lastTwoThirds), (.lastTwoThirds, .lastTwoThirds),
]

private let allPriors: [WindowAction?] = [nil] + WindowAction.allCases

// MARK: - 乱数（種を固定）

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func int(_ range: ClosedRange<Int>, _ rng: inout SplitMix64) -> CGFloat {
    CGFloat(Int.random(in: range, using: &rng))
}

// MARK: - unsnapped を試す入力

/// 今の枠・戻す大きさ・カーソル。カーソルはいつも今の枠の中（タイトルバーを掴んでいる）。
private struct UnsnapCase {
    let frame: CGRect, size: CGSize, cursor: CGPoint
    var result: CGRect { frame.unsnapped(to: size, cursor: cursor) }
    var shift: CGFloat { result.minX - frame.minX }
    /// 仕様の inset = min(32, size.width / 2)。
    var inset: CGFloat { min(32, size.width / 2) }
    /// 仕様のずらす上限 max(0, self.width - size.width)。
    var limit: CGFloat { max(0, frame.width - size.width) }
}

private let unsnapCases: [UnsnapCase] = {
    var cases: [UnsnapCase] = []
    // 手で選んだ格子: 戻す幅が今の幅より小さい・同じ・大きい、inset が幅の半分になる小さい幅、
    // カーソルが左端・真ん中・右端の近く。
    for frame in [box(0, 30, 1280, 1346), box(-1920, 385, 100, 1055), box(1280, -500, 1281, 700)] {
        for w: CGFloat in [1, 2, 40, 63, 64, 65, 99, 100, 101, 600, 1280, 1281, 2000] {
            for dx: CGFloat in [0, 1, 50, frame.width / 2, frame.width - 33, frame.width - 32, frame.width - 1] {
                cases.append(UnsnapCase(frame: frame, size: size(w, 300), cursor: pt(frame.minX + dx, frame.minY + 10)))
            }
        }
    }
    var rng = SplitMix64(state: 20_260_923)
    for _ in 0..<3000 {
        let w = int(1...3000, &rng), h = int(1...2000, &rng)
        let frame = box(int(-4000...4000, &rng), int(-2000...2000, &rng), w, h)
        let cursor = pt(frame.minX + int(0...Int(w) - 1, &rng), frame.minY + int(0...min(40, Int(h) - 1), &rng))
        cases.append(UnsnapCase(frame: frame, size: size(int(1...3000, &rng), int(1...2000, &rng)), cursor: cursor))
    }
    return cases
}()

/// flipped を試す枠と主画面の高さ。0.5 刻みの値も混ぜる。
private let flipCases: [(CGRect, CGRect, CGFloat)] = {
    var rng = SplitMix64(state: 1440)
    func rect() -> CGRect {
        box(int(-10000...10000, &rng) / 2, int(-6000...6000, &rng) / 2, int(0...8000, &rng) / 2, int(0...5000, &rng) / 2)
    }
    return (0..<500).map { _ in (rect(), rect(), int(1...6000, &rng) / 2) }
}()

// MARK: - ドラッグの偽物

// ドラッグ前のウィンドウ（主画面の上の、どの端にも付いていない枠）と、押す点（そのタイトルバー）。
private let before = box(500, 300, 800, 600)
private let grab = pt(900, 310)

// 主画面の点。
private let inside = pt(1000, 700) // どの端でもない
private let inside2 = pt(1100, 650) // どの端でもない
private let leftPoint = pt(2, 700) // 左の辺
private let leftPoint2 = pt(3, 900) // 同じ左の辺の別の点
private let topLeftPoint = pt(2, 10) // 左上の角
private let topPoint = pt(1280, 2) // 上の辺
private let bottomFirst = pt(400, 1438) // 下の辺の左の 1/3（e1 = 853 より左）
private let bottomMiddle = pt(1280, 1438) // 下の辺の中央
private let bottomMiddle2 = pt(1500, 1438) // 下の辺の中央の別の点
private let bottomLast = pt(2200, 1438) // 下の辺の右の 1/3（e2 = 1707 以上）
private let bottomLeftPoint = pt(10, 1430) // 左下の角

private let leftSnap = snapOn(mainScreen, .left, .firstThird)
private let topLeftSnap = snapOn(mainScreen, .topLeft, .leftHalf)
private let topSnap = snapOn(mainScreen, .top, .maximize)
private func bottomSnap(_ action: WindowAction) -> Snap { snapOn(mainScreen, .bottom, action) }

/// ウィンドウの枠を返す関数の偽物。呼ばれた回数（相手のアプリへの問い合わせの回数）を数える。
private final class FakeWindow {
    var frame: CGRect?
    private(set) var reads = 0
    func read() -> CGRect? {
        reads += 1
        return frame
    }
}

/// SnapTracker に押す・動かす・離す・Esc を渡す。drag(_:) ではウィンドウがカーソルについて動く
/// （押した点からのずれと同じだけ、押したときの枠がずれる）。
private final class Session {
    private var tracker = SnapTracker()
    let window = FakeWindow()
    let screens: [ScreenArea]
    private var base = before
    private var grabbed = grab

    init(screens: [ScreenArea] = [mainScreen]) { self.screens = screens }

    static func pressed(_ frame: CGRect = before, at point: CGPoint = grab, screens: [ScreenArea] = [mainScreen]) -> Session {
        let s = Session(screens: screens)
        s.press(frame, at: point)
        return s
    }

    func press(_ frame: CGRect?, at point: CGPoint = grab) {
        base = frame ?? before
        grabbed = point
        window.frame = frame
        tracker.press(at: point, window: frame)
    }

    /// カーソルが p にあるときの、カーソルについて動いたウィンドウの枠。
    func follow(_ p: CGPoint) -> CGRect { base.offsetBy(dx: p.x - grabbed.x, dy: p.y - grabbed.y) }

    @discardableResult func drag(_ p: CGPoint) -> [Effect] { drag(p, frame: follow(p)) }

    @discardableResult func drag(_ p: CGPoint, frame: CGRect?) -> [Effect] {
        window.frame = frame
        return tracker.drag(to: p, screens: screens, window: window.read)
    }

    @discardableResult func release(_ p: CGPoint) -> [Effect] { tracker.release(at: p, screens: screens) }

    @discardableResult func cancel() -> [Effect] { tracker.cancel() }
}

/// 効果の列から place の中身だけを取り出す。
private func places(_ effects: [Effect]) -> [(Snap, CGRect)] {
    effects.compactMap { effect in
        if case let .place(snap, initial) = effect { return (snap, initial) }
        return nil
    }
}

// MARK: - 幾何の補助

private func isInside(_ r: CGRect, _ b: CGRect) -> Bool {
    r.minX >= b.minX && r.maxX <= b.maxX && r.minY >= b.minY && r.maxY <= b.maxY
}

// MARK: - 表示

private func num(_ v: CGFloat) -> String {
    v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : "\(v)"
}

private let screenNames: [(ScreenArea, String)] = [
    (mainScreen, "主画面"), (rightScreen, "右"), (leftScreen, "左"), (upperScreen, "上"),
    (portraitScreen, "縦長"), (squareScreen, "正方形"), (barelyWideScreen, "1だけ横長"),
    (oddScreen, "奇数幅"), (dockLeftScreen, "Dockが左"),
]

private func screenName(_ s: ScreenArea) -> String {
    screenNames.first { $0.0 == s }?.1 ?? "frame\(show(s.frame))/visible\(show(s.visible))"
}

private func showSnap(_ s: Snap) -> String { "\(screenName(s.screen))・\(s.edge)・\(s.action)" }

private func showEffect(_ e: Effect) -> String {
    switch e {
    case let .began(initial, current): return "began(\(show(initial)) → \(show(current)))"
    case let .preview(s): return "preview(\(showSnap(s)))"
    case .hidePreview: return "hidePreview"
    case let .place(s, initial): return "place(\(showSnap(s)), initial: \(show(initial)))"
    }
}

private func show(_ value: Any?) -> String {
    guard let value else { return "nil" }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let inner = mirror.children.first?.value else { return "nil" }
        return show(inner)
    }
    if let r = value as? CGRect {
        return "(\(num(r.origin.x)), \(num(r.origin.y)), \(num(r.size.width)), \(num(r.size.height)))"
    }
    if let p = value as? CGPoint { return "(\(num(p.x)), \(num(p.y)))" }
    if let s = value as? ScreenArea { return screenName(s) }
    if let s = value as? Snap { return showSnap(s) }
    if let e = value as? Effect { return showEffect(e) }
    if mirror.displayStyle == .collection || mirror.displayStyle == .set {
        return "[" + mirror.children.map { show($0.value) }.joined(separator: ", ") + "]"
    }
    return "\(value)"
}

// MARK: - 実行

@main
struct SnapLayoutTests {
    static var failures = 0

    /// 実際と期待を同じ型で比べる。
    static func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        let ok = actual == expected
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)  期待=\(show(expected)) 実際=\(show(actual))")
    }

    /// 性質を全部の入力で確かめる。broken が理由を返した入力があれば失敗で、最初の1つを出す。
    /// 入力が 0 通りなら何も確かめていないので失敗にする。
    static func checkAll<C>(_ name: String, _ cases: [C], _ broken: (C) -> String?) {
        let found = cases.compactMap(broken)
        let ok = !cases.isEmpty && found.isEmpty
        if !ok { failures += 1 }
        let detail = cases.isEmpty ? "入力が 0 通り"
            : found.isEmpty ? "\(cases.count) 通り"
            : "\(cases.count) 通り中 \(found.count) 通りで崩れた。例: \(found[0])"
        print("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)")
    }

    static func main() {
        constants()
        whichScreen()
        edges()
        edgePriority()
        edgeActions()
        bottomThirds()
        snapFrames()
        unsnapped()
        trackerBegin()
        trackerStill()
        trackerNoWindow()
        trackerMoving()
        trackerBottom()
        trackerRelease()
        trackerAfterRelease()
        trackerCancel()
        flipped()
        restoreIfStillAt()
        dragHistory()

        print(failures == 0 ? "\nすべて通過" : "\n\(failures) 件 失敗")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 定数

    static func constants() {
        check("辺の幅 margin は 5", SnapLayout.margin, 5)
        check("角の足し幅 cornerSize は 20（角の広さは 25）", SnapLayout.cornerSize, 20)
        check("動かないまま諦める距離は 50", SnapTracker.giveUpDistance, 50)
    }

    // MARK: どの画面か

    static func whichScreen() {
        // 表: 点 → その点を frame に含む画面の端と操作。frame は左端・上端を含み、右端・下端を含まないので、
        // 2枚の境目の上の点は、そこが左端（上端）になっている側の画面のもの。
        let borders: [(String, CGPoint, Snap?)] = [
            ("主画面と右の画面の境目 x = 2560 は右の画面の左の辺", pt(2560, 500), snapOn(rightScreen, .left, .firstThird)),
            ("境目の 1 手前 x = 2559 は主画面の右の辺", pt(2559, 500), snapOn(mainScreen, .right, .lastThird)),
            ("左の画面との境目 x = 0 は主画面の左の辺", pt(0, 700), snapOn(mainScreen, .left, .firstThird)),
            ("x が負: 境目の 1 手前 x = -1 は左の画面の右の辺", pt(-1, 700), snapOn(leftScreen, .right, .lastThird)),
            ("上の画面との境目 y = 0 は主画面の上の辺", pt(2000, 0), snapOn(mainScreen, .top, .maximize)),
            // 上の画面の e1 = 1500 + 640 = 2140 なので、x = 2000 は左の 1/3。
            ("y が負: 境目の 1 手前 y = -1 は上の画面の下の辺", pt(2000, -1), snapOn(upperScreen, .bottom, .firstThird)),
            ("y が負: 上の画面の上の辺", pt(3000, -1080), snapOn(upperScreen, .top, .maximize)),
        ]
        for (name, p, expected) in borders { check("画面: \(name)", snap(p, allScreens), expected) }

        // 表: 各画面の四隅。右端・下端は含まないので、右下の隅は (maxX - 1, maxY - 1)。
        let corners: [(ScreenArea, CGPoint, SnapEdge, WindowAction)] = [
            (mainScreen, pt(0, 0), .topLeft, .leftHalf), (mainScreen, pt(2559, 0), .topRight, .rightHalf),
            (mainScreen, pt(0, 1439), .bottomLeft, .bottomLeft), (mainScreen, pt(2559, 1439), .bottomRight, .bottomRight),
            (rightScreen, pt(2560, 0), .topLeft, .leftHalf), (rightScreen, pt(4479, 0), .topRight, .rightHalf),
            (rightScreen, pt(2560, 1079), .bottomLeft, .bottomLeft), (rightScreen, pt(4479, 1079), .bottomRight, .bottomRight),
            (leftScreen, pt(-1920, 360), .topLeft, .leftHalf), (leftScreen, pt(-1, 360), .topRight, .rightHalf),
            (leftScreen, pt(-1920, 1439), .bottomLeft, .bottomLeft), (leftScreen, pt(-1, 1439), .bottomRight, .bottomRight),
            (upperScreen, pt(1500, -1080), .topLeft, .leftHalf), (upperScreen, pt(3419, -1080), .topRight, .rightHalf),
            (upperScreen, pt(1500, -1), .bottomLeft, .bottomLeft), (upperScreen, pt(3419, -1), .bottomRight, .bottomRight),
        ]
        for (screen, p, edge, action) in corners {
            check("四隅: \(screenName(screen))の画面の \(show(p)) は \(edge)", snap(p, allScreens), snapOn(screen, edge, action))
        }

        let outside: [(String, CGPoint)] = [
            ("右の画面の右端ちょうど x = 4480", pt(4480, 500)),
            ("主画面の下端ちょうど y = 1440", pt(1280, 1440)),
            ("左の画面より 1 左", pt(-1921, 700)),
            ("左の画面の上端より 1 上（主画面の左の外）", pt(-500, 359)),
            ("上の画面の左の外（主画面の上の外）", pt(1000, -1)),
            ("上の画面の右端ちょうど x = 3420（右の画面の上の外）", pt(3420, -500)),
            ("上の画面の上端より 1 上", pt(3000, -1081)),
            ("右の画面の下の外（主画面の右の外）", pt(2560, 1200)),
        ]
        for (name, p) in outside { check("画面の外は nil: \(name)", snap(p, allScreens), nil) }
        check("画面の配列が空なら nil", snap(leftPoint, []), nil)

        // frame の重なる2枚（visible だけ違う）。どちらの並びでも先頭が選ばれる。
        let twin = ScreenArea(frame: mainScreen.frame, visible: box(0, 25, 2560, 1415))
        check("frame が重なる画面では配列の先頭から見て最初の画面",
              [snap(leftPoint, [mainScreen, twin])?.screen, snap(leftPoint, [twin, mainScreen])?.screen], [mainScreen, twin])

        // ここが設計の判断: 縦長の画面ではスナップしない。
        check("縦長の画面では端でも nil", snap(pt(2562, 500), [mainScreen, portraitScreen]), nil)
        check("縦長の画面では角でも nil", snap(pt(2560, -400), [mainScreen, portraitScreen]), nil)
        // 縦長かどうかは visible で見る（2026-09-23 に frame から変えた）。1/3 を縦に割るか横に割るかを
        // 決めているのが visible なので、frame で見ると、スナップはするのに 1/3 が上下に割れる画面が出る。
        // この画面は frame が正方形で visible が横長なので、スナップし、左の辺は左 1/3 になる。
        check("frame が正方形でも visible が横長ならスナップする（向きは visible で見る）",
              snap(pt(-998, 500), [squareScreen]), snapOn(squareScreen, .left, .firstThird))
        // 逆向き。frame は横長だが、横に Dock があって visible が縦長。frame で見ていた版では
        // スナップし、左の辺の「左 1/3」が上の 1/3 として置かれていた。
        let tallVisible = ScreenArea(frame: box(0, 0, 1100, 1000), visible: box(150, 25, 950, 975))
        check("frame が横長でも visible が縦長ならスナップしない", snap(pt(2, 500), [tallVisible]), nil)
        check("幅が高さより 1 だけ大きい画面ではスナップする",
              snap(pt(-999, 500), [barelyWideScreen]), snapOn(barelyWideScreen, .left, .firstThird))
        check("画面の中でも端でなければ nil（例）", snap(pt(1280, 700)), nil)
    }

    // MARK: 端のどこか

    static func edges() {
        let f = mainScreen.frame
        // 表: 点 → 端。距離は 左 = x、右 = 2560 - x、上 = y、下 = 1440 - y。
        // 角は 25 未満、辺は 5 未満（境目ちょうどは含まない）。
        let rows: [(String, CGPoint, SnapEdge?)] = [
            ("左上の角の内側ぎりぎり（左 24・上 24）", pt(24, 24), .topLeft),
            ("左が 25 なら左上の角でない", pt(25, 24), nil),
            ("上が 25 なら左上の角でない", pt(24, 25), nil),
            ("右上の角の内側ぎりぎり（右 24・上 24）", pt(2536, 24), .topRight),
            ("右が 25 なら右上の角でない", pt(2535, 24), nil),
            ("上が 25 なら右上の角でない", pt(2536, 25), nil),
            ("左下の角の内側ぎりぎり（左 24・下 24）", pt(24, 1416), .bottomLeft),
            ("左が 25 なら左下の角でない", pt(25, 1416), nil),
            ("下が 25 なら左下の角でない", pt(24, 1415), nil),
            ("右下の角の内側ぎりぎり（右 24・下 24）", pt(2536, 1416), .bottomRight),
            ("右が 25 なら右下の角でない", pt(2535, 1416), nil),
            ("下が 25 なら右下の角でない", pt(2536, 1415), nil),
            ("角の境目は小数でも未満（左 24.9・上 24.9 は角）", pt(24.9, 24.9), .topLeft),

            ("左の辺: 左 0", pt(0, 700), .left),
            ("左の辺: 左 4", pt(4, 700), .left),
            ("左の辺: 左 4.9", pt(4.9, 700), .left),
            ("左 5 は辺でない", pt(5, 700), nil),
            ("左 6 は辺でない", pt(6, 700), nil),
            ("右の辺: 右 1", pt(2559, 700), .right),
            ("右の辺: 右 4", pt(2556, 700), .right),
            ("右 5 は辺でない", pt(2555, 700), nil),
            ("右 6 は辺でない", pt(2554, 700), nil),
            ("上の辺: 上 0", pt(1280, 0), .top),
            ("上の辺: 上 4", pt(1280, 4), .top),
            ("上 5 は辺でない", pt(1280, 5), nil),
            ("上 6 は辺でない", pt(1280, 6), nil),
            ("下の辺: 下 1", pt(1280, 1439), .bottom),
            ("下の辺: 下 4", pt(1280, 1436), .bottom),
            ("下 5 は辺でない", pt(1280, 1435), nil),
            ("下 6 は辺でない", pt(1280, 1434), nil),
            ("真ん中はどこでもない", pt(1280, 700), nil),

            // ここが設計の判断: 角は辺よりずっと広い。辺の 5 より内側でも、角の 25 の中なら角。
            ("左 4・上 24 は左の辺でなく左上の角", pt(4, 24), .topLeft),
            ("左 24・上 4 は上の辺でなく左上の角", pt(24, 4), .topLeft),
            ("右 4・下 24 は右の辺でなく右下の角", pt(2556, 1416), .bottomRight),
            ("右 24・下 4 は下の辺でなく右下の角", pt(2536, 1436), .bottomRight),
            ("左 4・上 25 は角を外れて左の辺", pt(4, 25), .left),
            ("左 25・上 4 は角を外れて上の辺", pt(25, 4), .top),
            ("右 4・下 25 は角を外れて右の辺", pt(2556, 1415), .right),
            ("右 25・下 4 は角を外れて下の辺", pt(2535, 1436), .bottom),
            ("左 4・下 25 は角を外れて左の辺", pt(4, 1415), .left),
            ("右 4・上 25 は角を外れて右の辺", pt(2556, 25), .right),
        ]
        for (name, p, expected) in rows { check("端: \(name)", SnapLayout.edge(of: p, in: f), expected) }

        // 距離は frame の端から測る（原点に置いていない枠）。
        check("端: 原点にない枠でも左の辺は minX から測る", SnapLayout.edge(of: pt(-1916, 900), in: leftScreen.frame), .left)
        check("端: 原点にない枠で minX から 5 は辺でない", SnapLayout.edge(of: pt(-1915, 900), in: leftScreen.frame), nil)
        check("端: 原点にない枠でも上の辺は minY から測る", SnapLayout.edge(of: pt(2500, -1076), in: upperScreen.frame), .top)
        check("端: 原点にない枠で minY から 5 は辺でない", SnapLayout.edge(of: pt(2500, -1075), in: upperScreen.frame), nil)
    }

    // MARK: 角・辺の優先順位

    static func edgePriority() {
        // 表: 小さい枠で、角や辺の条件が2つ以上同時に当てはまるとき、仕様の並びで先のほう。
        // 辺どうし（左と上など）は角が先に当たるので、重なり得るのは左と右・上と下だけ。
        let rows: [(String, CGRect, CGPoint, SnapEdge)] = [
            ("4つの角すべてに当てはまれば左上", box(0, 0, 40, 40), pt(20, 20), .topLeft),
            ("左上と右上なら左上", box(0, 0, 40, 60), pt(20, 20), .topLeft),
            ("左上と左下なら左上", box(0, 0, 60, 40), pt(20, 20), .topLeft),
            ("右上と右下なら右上", box(0, 0, 60, 40), pt(40, 20), .topRight),
            ("左下と右下なら左下", box(0, 0, 40, 60), pt(20, 40), .bottomLeft),
            ("左と右の辺なら左", box(0, 0, 8, 100), pt(4, 50), .left),
            ("上と下の辺なら上", box(0, 0, 100, 8), pt(50, 4), .top),
        ]
        for (name, frame, p, expected) in rows { check("優先: \(name)", SnapLayout.edge(of: p, in: frame), expected) }
    }

    // MARK: 端ごとの操作

    static func edgeActions() {
        check("表の端と下の辺で SnapEdge を全部覆う", Set(edgeActionTable.map { $0.0 } + [.bottom]), Set(SnapEdge.allCases))
        for (edge, p, action) in edgeActionTable {
            check("表: \(edge) → \(action)", SnapLayout.action(for: edge, at: p, in: mainScreen.frame, prior: nil), action)
        }
        for (edge, p, action) in edgeActionTable {
            check("表を snap 越しに: \(show(p)) は \(edge)・\(action)", snap(p), snapOn(mainScreen, edge, action))
        }
        let rowsAndPriors = edgeActionTable.flatMap { row in allPriors.map { (row, $0) } }
        checkAll("下の辺以外は prior に依らず表のとおり", rowsAndPriors) { c in
            let ((edge, p, action), prior) = c
            let got = SnapLayout.action(for: edge, at: p, in: mainScreen.frame, prior: prior)
            return got == action ? nil : "\(edge) で prior \(show(prior)) のとき \(got)"
        }
        check("上の辺は左の 1/3 の上でも maximize（位置で分けない）", snap(pt(100, 2)), topSnap)
        check("上の辺は右の 1/3 の上でも maximize（位置で分けない）", snap(pt(2400, 2)), topSnap)
    }

    // MARK: 下の辺の3分割

    static func bottomThirds() {
        // 主画面（幅 2560）: e1 = round(853.33) = 853、e2 = round(1706.67) = 1707。
        let mainRows: [(String, CGPoint, WindowAction)] = [
            ("e1 = 853 の 1 手前は左の 1/3", pt(852, 1438), .firstThird),
            ("e1 の 0.5 手前は左の 1/3", pt(852.5, 1438), .firstThird),
            ("e1 = 853 ちょうどは中央", pt(853, 1438), .centerThird),
            ("e2 = 1707 の 1 手前は中央（1706.67 を切り捨てない）", pt(1706, 1438), .centerThird),
            ("e2 の 0.5 手前は中央", pt(1706.5, 1438), .centerThird),
            ("e2 = 1707 ちょうどは右の 1/3", pt(1707, 1438), .lastThird),
            ("左の角のすぐ外（左 25）は左の 1/3", pt(25, 1438), .firstThird),
            ("右の角のすぐ外（右 25）は右の 1/3", pt(2535, 1438), .lastThird),
        ]
        for (name, p, action) in mainRows { check("下の辺: \(name)", snap(p), bottomSnap(action)) }

        // 幅 1001（x は -1001 から）: e1 = -1001 + round(333.67) = -667、e2 = -1001 + round(667.33) = -334。
        let oddRows: [(String, CGPoint, WindowAction)] = [
            ("幅 1001: e1 = -667 の 1 手前は左の 1/3（333.67 を切り捨てない）", pt(-668, 799), .firstThird),
            ("幅 1001: e1 の 0.2 手前は左の 1/3（境目は 333.67 でなく四捨五入した 334）", pt(-667.2, 799), .firstThird),
            ("幅 1001: e1 = -667 ちょうどは中央", pt(-667, 799), .centerThird),
            ("幅 1001: e2 = -334 の 0.2 手前は中央", pt(-334.2, 799), .centerThird),
            ("幅 1001: e2 = -334 ちょうどは右の 1/3", pt(-334, 799), .lastThird),
            ("幅 1001: e2 の 0.2 先は右の 1/3（境目は 667.33 でなく四捨五入した 667）", pt(-333.8, 799), .lastThird),
        ]
        for (name, p, action) in oddRows {
            check("下の辺: \(name)", snap(p, [oddScreen]), snapOn(oddScreen, .bottom, action))
        }

        // 幅 1920（3 で割り切れる）の右の画面: e1 = 3200、e2 = 3840。
        let evenRows: [(String, CGPoint, WindowAction)] = [
            ("幅 1920: e1 = 3200 の 1 手前は左の 1/3", pt(3199, 1078), .firstThird),
            ("幅 1920: e1 = 3200 ちょうどは中央", pt(3200, 1078), .centerThird),
            ("幅 1920: e2 = 3840 の 1 手前は中央", pt(3839, 1078), .centerThird),
            ("幅 1920: e2 = 3840 ちょうどは右の 1/3", pt(3840, 1078), .lastThird),
        ]
        for (name, p, action) in evenRows {
            check("下の辺: \(name)", snap(p, allScreens), snapOn(rightScreen, .bottom, action))
        }

        // 3 で割った余りが 0・1・2 の幅、原点が 0・負・正の枠で、x を 0.5 ずつ全部動かして仕様の式と照らす。
        let frames = [
            mainScreen.frame, oddScreen.frame, rightScreen.frame,
            box(0, 0, 1000, 700), box(0, 0, 1001, 700), box(-7, 0, 1002, 700), box(333, -900, 1003, 500),
        ]
        var sweep: [(CGRect, CGFloat)] = []
        for f in frames {
            for x in stride(from: f.minX, to: f.maxX, by: 0.5) { sweep.append((f, x)) }
        }
        checkAll("下の辺の3分割はどの x でも仕様の境目の式どおり（prior なし）", sweep) { c in
            let (f, x) = c
            let e1 = specBorder(f.minX, f.width, 1, 3), e2 = specBorder(f.minX, f.width, 2, 3)
            let expected: WindowAction = x < e1 ? .firstThird : x >= e2 ? .lastThird : .centerThird
            let got = SnapLayout.action(for: .bottom, at: pt(x, f.maxY - 1), in: f, prior: nil)
            return got == expected ? nil : "枠 \(show(f)) の x = \(num(x)) で \(got)（期待 \(expected)）"
        }

        // 境目は visible で決める（2026-09-23 に frame から変えた）。仕様の「1/3 に並べたウィンドウの境目と
        // 同じ位置」を正とした。Dock が横にあると frame の e1 = 853、visible の e1 = 80 + 827 = 907 と
        // 食い違い、frame で決めるとカーソルのある区画と出てくる枠がずれる。x = 880 は visible の左 1/3 の中。
        check("下の辺の境目は frame でなく visible で決める（Dock が左の画面）",
              snap(pt(880, 1438), [dockLeftScreen]), snapOn(dockLeftScreen, .bottom, .firstThird))

        // prior（いま見せている行き先の操作）
        for (prior, action) in middlePriorTable {
            check("下の辺の中央で prior \(show(prior)) なら \(action)", snap(bottomMiddle, prior: prior), bottomSnap(action))
        }
        let otherPriors = WindowAction.allCases.filter { a in !middlePriorTable.contains { $0.0 == a } }
        checkAll("下の辺の中央で prior が表に無い操作（centerThird・leftHalf・bottomLeft など）なら centerThird", otherPriors) { prior in
            let got = SnapLayout.action(for: .bottom, at: bottomMiddle, in: mainScreen.frame, prior: prior)
            return got == .centerThird ? nil : "prior \(prior) で \(got)"
        }
        checkAll("下の辺の e1 の 1 手前は prior に依らず左の 1/3", allPriors) { prior in
            let got = SnapLayout.action(for: .bottom, at: pt(852, 1438), in: mainScreen.frame, prior: prior)
            return got == .firstThird ? nil : "prior \(show(prior)) で \(got)"
        }
        checkAll("下の辺の e2 ちょうどは prior に依らず右の 1/3", allPriors) { prior in
            let got = SnapLayout.action(for: .bottom, at: pt(1707, 1438), in: mainScreen.frame, prior: prior)
            return got == .lastThird ? nil : "prior \(show(prior)) で \(got)"
        }
        check("下の辺の中央の端（e1 ちょうど）でも prior firstThird なら 2/3", snap(pt(853, 1438), prior: .firstThird),
              bottomSnap(.firstTwoThirds))
        check("下の辺の中央の端（e2 の 1 手前）でも prior lastThird なら 2/3", snap(pt(1706, 1438), prior: .lastThird),
              bottomSnap(.lastTwoThirds))
    }

    // MARK: Snap と置く枠

    static func snapFrames() {
        // 仕様の例（主画面 frame (0, 0, 2560, 1440)、visible (0, 30, 2560, 1346)）。
        let examples: [(String, CGPoint, WindowAction?, SnapEdge, WindowAction, CGRect)] = [
            ("(2, 700)", pt(2, 700), nil, .left, .firstThird, box(0, 30, 853, 1346)),
            ("(10, 10)", pt(10, 10), nil, .topLeft, .leftHalf, box(0, 30, 1280, 1346)),
            ("(1280, 1438)・prior nil", pt(1280, 1438), nil, .bottom, .centerThird, box(853, 30, 854, 1346)),
            ("(1280, 1438)・prior firstThird", pt(1280, 1438), .firstThird, .bottom, .firstTwoThirds, box(0, 30, 1707, 1346)),
        ]
        for (name, p, prior, edge, action, frame) in examples {
            let s = snap(p, prior: prior)
            check("例: \(name) は \(edge)・\(action)", s, snapOn(mainScreen, edge, action))
            check("例: \(name) の枠", s?.frame, frame)
        }

        // 以下は前の仕様の境目の式で手で計算した値。
        let frames: [(String, CGPoint, CGRect)] = [
            ("主画面の右上の角は右半分", pt(2550, 10), box(1280, 30, 1280, 1346)),
            ("主画面の上の辺は最大化（visible いっぱい）", pt(1280, 2), box(0, 30, 2560, 1346)),
            ("主画面の右の辺は右の 1/3", pt(2558, 700), box(1707, 30, 853, 1346)),
            ("主画面の左下の角は左下の 1/4（高さ 1346 の半分 673）", pt(10, 1430), box(0, 703, 1280, 673)),
            ("主画面の右下の角は右下の 1/4", pt(2550, 1430), box(1280, 703, 1280, 673)),
            ("主画面の下の辺の右は右の 1/3", pt(2200, 1438), box(1707, 30, 853, 1346)),
            ("右の画面の左の辺は右の画面の左の 1/3", pt(2562, 500), box(2560, 25, 640, 1055)),
            ("左の画面（x が負）の左下の角（高さ 1055 の半分は上が 528）", pt(-1918, 1435), box(-1920, 913, 960, 527)),
            ("左の画面の右の辺", pt(-2, 900), box(-640, 385, 640, 1055)),
            ("上の画面（y が負）の上の辺は、その画面の visible いっぱい", pt(3000, -1079), box(1500, -1055, 1920, 1055)),
        ]
        for (name, p, frame) in frames { check("置く枠: \(name)", snap(p, allScreens)?.frame, frame) }
        check("置く枠: Snap を直に作っても、その画面の visible の格子",
              Snap(screen: rightScreen, edge: .right, action: .lastThird).frame, box(3840, 25, 640, 1055))

        // ここが設計の判断: ウィンドウがどこにあっても、カーソルのある画面に置く。
        let s = Session.pressed(screens: [mainScreen, rightScreen])
        s.drag(pt(2562, 500), frame: box(2000, 300, 800, 600)) // ウィンドウの大半（幅 560 対 240）は主画面の上
        check("置く枠: ウィンドウの大半が主画面にあっても、カーソルのある右の画面に置く",
              places(s.release(pt(2562, 500))).map { $0.0.frame }, [box(2560, 25, 640, 1055)])

        // 各画面の内側で、端からの距離が 5 未満の点を周に沿って並べる。
        var nearEdges: [(ScreenArea, CGPoint)] = []
        for screen in allScreens {
            let f = screen.frame
            for d: CGFloat in [0, 1, 2.5, 4, 4.9] {
                for x in stride(from: f.minX, to: f.maxX, by: 37) {
                    nearEdges += [(screen, pt(x, f.minY + d)), (screen, pt(x, f.maxY - max(d, 0.1)))]
                }
                for y in stride(from: f.minY, to: f.maxY, by: 37) {
                    nearEdges += [(screen, pt(f.minX + d, y)), (screen, pt(f.maxX - max(d, 0.1), y))]
                }
            }
        }
        checkAll("横長の画面の内側で端から 5 未満の点は、どこでもその画面にスナップする", nearEdges) { c in
            let (screen, p) = c
            guard let s = snap(p, allScreens) else { return "\(show(p)) で nil" }
            return s.screen == screen ? nil : "\(show(p)) が \(screenName(s.screen))の画面"
        }
        checkAll("置く枠はいつもカーソルのある画面の visible の中", nearEdges) { c in
            let (screen, p) = c
            guard let f = snap(p, allScreens)?.frame else { return "\(show(p)) で枠が無い" }
            return isInside(f, screen.visible) ? nil : "\(show(p)) で \(show(f)) が \(screenName(screen))の visible の外"
        }
    }

    // MARK: スナップを外すときの枠

    static func unsnapped() {
        check("例: 右半分から戻すと、カーソルが右端から 32 内側に来るまで右へずらす",
              box(1280, 30, 1280, 1346).unsnapped(to: size(600, 400), cursor: pt(2280, 40)), box(1712, 30, 600, 400))
        check("例: 掴んだ位置が戻した幅に収まっていればずらさない",
              box(0, 30, 1280, 1346).unsnapped(to: size(600, 400), cursor: pt(100, 40)), box(0, 30, 600, 400))
        check("例: 戻す大きさのほうが大きければずらさない",
              box(100, 100, 400, 300).unsnapped(to: size(800, 600), cursor: pt(450, 110)), box(100, 100, 800, 600))

        // 以下は仕様の式で手で計算した値。
        check("ずらすのは元の枠の右端まで（needed 702 を上限 680 で止める）",
              box(0, 30, 1280, 1346).unsnapped(to: size(600, 400), cursor: pt(1270, 40)), box(680, 30, 600, 400))
        check("needed がちょうど 0 ならずらさない",
              box(0, 30, 1280, 1346).unsnapped(to: size(600, 400), cursor: pt(568, 40)), box(0, 30, 600, 400))
        check("needed が 1 なら 1 ずらす",
              box(0, 30, 1280, 1346).unsnapped(to: size(600, 400), cursor: pt(569, 40)), box(1, 30, 600, 400))
        check("同じ幅に戻すならずらさない（上限 0）",
              box(100, 100, 600, 400).unsnapped(to: size(600, 200), cursor: pt(690, 110)), box(100, 100, 600, 200))
        check("幅 40 に戻すなら inset は 20（幅の半分）",
              box(0, 0, 400, 300).unsnapped(to: size(40, 30), cursor: pt(200, 10)), box(180, 0, 40, 30))
        check("幅 63 に戻すなら inset は 31.5（幅の半分）",
              box(0, 0, 400, 300).unsnapped(to: size(63, 30), cursor: pt(200, 10)), box(168.5, 0, 63, 30))
        check("幅 64 に戻すなら inset は 32",
              box(0, 0, 400, 300).unsnapped(to: size(64, 30), cursor: pt(200, 10)), box(168, 0, 64, 30))
        check("幅 65 に戻しても inset は 32 のまま",
              box(0, 0, 400, 300).unsnapped(to: size(65, 30), cursor: pt(200, 10)), box(167, 0, 65, 30))
        check("x が負の枠でも同じ式",
              box(-1920, 385, 960, 1055).unsnapped(to: size(500, 300), cursor: pt(-1000, 400)), box(-1468, 385, 500, 300))

        // 性質（手で選んだ格子と、種を固定した乱数の入力。カーソルはいつも今の枠の中）
        checkAll("unsnapped: 結果の大きさは戻す大きさ", unsnapCases) { c in
            c.result.size == c.size ? nil : "\(show(c.frame)) を \(c.size) に戻して \(show(c.result))"
        }
        checkAll("unsnapped: 縦は動かない", unsnapCases) { c in
            c.result.minY == c.frame.minY ? nil : "\(show(c.frame)) を戻して \(show(c.result))"
        }
        checkAll("unsnapped: 右へのずれは 0 以上（左へはずらさない）", unsnapCases) { c in
            c.shift >= 0 ? nil : "\(show(c.frame)) を戻して \(show(c.result))"
        }
        checkAll("unsnapped: 元の枠の右端を越えない（戻す幅のほうが大きければずらさない）", unsnapCases) { c in
            c.shift <= c.limit ? nil : "\(show(c.frame)) を幅 \(num(c.size.width)) に戻して \(show(c.result))"
        }
        let shifted = unsnapCases.filter { $0.shift > 0 }
        checkAll("unsnapped: ずらしたならカーソルは結果の中", shifted) { c in
            c.result.minX <= c.cursor.x && c.cursor.x <= c.result.maxX ? nil
                : "\(show(c.frame)) をカーソル \(show(c.cursor)) で戻して \(show(c.result))"
        }
        let shiftedBelowLimit = shifted.filter { $0.shift < $0.limit }
        checkAll("unsnapped: 上限に届かずにずらしたなら、カーソルは結果の右端から inset のところ", shiftedBelowLimit) { c in
            abs(c.result.maxX - c.inset - c.cursor.x) < 1e-9 ? nil
                : "\(show(c.frame)) をカーソル \(show(c.cursor)) で戻して \(show(c.result))"
        }
        let grabbedNear = unsnapCases.filter { $0.cursor.x - $0.frame.minX <= $0.size.width - $0.inset }
        checkAll("unsnapped: 掴んだ位置が戻した幅の右端から inset より内側ならずらさない", grabbedNear) { c in
            c.shift == 0 ? nil : "\(show(c.frame)) をカーソル \(show(c.cursor)) で戻して \(show(c.result))"
        }
        let grabbedFar = unsnapCases.filter { $0.cursor.x - $0.frame.minX > $0.size.width - $0.inset && $0.limit > 0 }
        checkAll("unsnapped: 掴んだ位置が右端から inset より外で、ずらす余地があればずらす", grabbedFar) { c in
            c.shift > 0 ? nil : "\(show(c.frame)) をカーソル \(show(c.cursor)) で戻して \(show(c.result))"
        }
        checkAll("unsnapped: カーソルの y は結果に影響しない", unsnapCases) { c in
            let other = c.frame.unsnapped(to: c.size, cursor: pt(c.cursor.x, c.cursor.y + 777))
            return other == c.result ? nil : "\(show(c.result)) と \(show(other))"
        }
    }

    // MARK: SnapTracker — 動かし始め

    static func trackerBegin() {
        var s = Session.pressed()
        check("追跡: 押して位置だけ動けば began（ドラッグ前の枠と今の枠）",
              s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        s = .pressed()
        check("追跡: 動かし始めた点が端なら began に続けて preview",
              s.drag(leftPoint), [.began(initial: before, current: s.follow(leftPoint)), .preview(leftSnap)])

        s = .pressed()
        s.drag(inside)
        check("追跡: began は1回だけ（動かしている間は繰り返さない）", s.drag(inside2), [])

        s = .pressed()
        check("追跡: 位置が 1 だけ動いても動かし始め（許容差なし、要確認）", s.drag(pt(901, 310), frame: before.offsetBy(dx: 1, dy: 0)),
              [.began(initial: before, current: before.offsetBy(dx: 1, dy: 0))])

        s = .pressed()
        check("追跡: 縦にだけ 1 動いても動かし始め", s.drag(pt(900, 311), frame: before.offsetBy(dx: 0, dy: 1)),
              [.began(initial: before, current: before.offsetBy(dx: 0, dy: 1))])

        // ここが設計の判断: 移動とみなすのは大きさが変わらずに位置だけ変わったときだけ。
        // 大きさを変えるドラッグは押した点から 28 のところで試す（50 を超えると、大きさと関係なく諦めてしまい、
        // 大きさの判定を試したことにならない）。
        let resizeCursor = pt(920, 330)
        s = .pressed()
        check("追跡: 大きさが変われば何も出さない", s.drag(resizeCursor, frame: box(500, 300, 900, 690)), [])

        s = .pressed()
        s.drag(resizeCursor, frame: box(500, 300, 900, 690))
        check("追跡: 大きさを変えたドラッグは、そのあと位置だけ動いて端に来ても何も出さない", s.drag(leftPoint), [])

        s = .pressed()
        s.drag(resizeCursor, frame: box(500, 300, 800, 690)) // 下の辺を掴んで伸ばす
        check("追跡: 高さだけ変わっても相手にしない（そのあと端に来ても何も出さない）", s.drag(leftPoint), [])

        s = .pressed()
        s.drag(pt(880, 290), frame: box(480, 280, 820, 620)) // 左上の角を掴んで広げる（位置も変わる）
        check("追跡: 位置と大きさが両方変われば相手にしない（そのあと端に来ても何も出さない）", s.drag(leftPoint), [])

        s = .pressed()
        s.drag(resizeCursor, frame: box(500, 300, 801, 600))
        check("追跡: 大きさが 1 だけ違っても相手にしない（許容差なし、要確認）", s.drag(leftPoint), [])

        s = .pressed()
        s.drag(resizeCursor, frame: box(500, 300, 900, 690))
        s.drag(leftPoint)
        s.drag(topPoint)
        check("追跡: 大きさを変えたと分かったあとは window を呼ばない", s.window.reads, 1)
    }

    // MARK: SnapTracker — 動かないまま

    static func trackerStill() {
        // 実際に壊れた入力（2026-09-23）。ウィンドウサーバーの位置はイベント1つ分遅れて動く
        // （試験用のウィンドウで測った）。最初の drag の時点ではまだ動いておらず、それが押した点から
        // 50 より遠いと、最初の drag だけで諦めていた。合成したドラッグで、1歩目が 72 離れていたとき
        // スナップも引き剥がしも起きなかった。1つ遅れを見込み、次の drag で動いていれば動かし始め。
        var s = Session.pressed()
        s.drag(pt(964, 344), frame: before) // 押した点から 72。ウィンドウはまだ動いていない
        check("追跡: 最初の drag で 50 より遠くても、まだ動いていないだけなら諦めない（1つ遅れを見込む）",
              s.drag(pt(1028, 378)), [.began(initial: before, current: s.follow(pt(1028, 378)))])

        s = .pressed()
        check("追跡: 動かないまま 50 以内なら何も出さない", s.drag(pt(940, 310), frame: before), [])

        s = .pressed()
        s.drag(pt(940, 310), frame: before)
        check("追跡: 動かないまま 50 以内のあとで動けば began", s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        s = .pressed()
        s.drag(pt(950, 310), frame: before)
        check("追跡: 押した点からちょうど 50（横）ならまだ諦めない", s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        s = .pressed()
        s.drag(pt(930, 350), frame: before)
        check("追跡: 押した点からちょうど 50（斜め 30・40）ならまだ諦めない",
              s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        // 以下の「諦める」は 2026-09-23 に書き直した。前は1回の drag が 50 を超えただけで諦めるのを
        // 固定していたが、読める枠が1つ遅れて動くことを見込むようにしたので、1つ前の drag の時点で
        // 50 を超えていて、今の drag でもまだ動いていないときに諦める。
        s = .pressed()
        s.drag(pt(951, 310), frame: before)
        s.drag(pt(952, 310), frame: before)
        check("追跡: 51 離れ、次の drag でもまだ動いていなければ諦める（そのあと動いても何も出さない）", s.drag(inside), [])

        s = .pressed()
        s.drag(pt(950, 310), frame: before)
        s.drag(pt(960, 310), frame: before)
        check("追跡: 1つ前がちょうど 50 なら、次の drag で動いていなくてもまだ諦めない",
              s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        s = .pressed()
        s.drag(pt(935, 340), frame: before)
        check("追跡: 距離はユークリッド（斜め 35・30 は 46.1 なので諦めない）",
              s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        s = .pressed()
        s.drag(pt(936, 346), frame: before)
        s.drag(pt(937, 347), frame: before)
        check("追跡: 距離はユークリッド（斜め 36・36 は 50.9 なので、次も動いていなければ諦める）", s.drag(inside), [])

        s = .pressed()
        s.drag(pt(940, 310), frame: before)
        s.drag(pt(980, 310), frame: before)
        s.drag(pt(985, 310), frame: before)
        check("追跡: 距離は押した点から測る（1つ前の点が直前の点から 40 でも、押した点から 80 なら諦める）",
              s.drag(inside), [])

        s = .pressed()
        check("追跡: 位置が変わっていれば、押した点から 50 より遠くても began",
              s.drag(pt(1300, 800)), [.began(initial: before, current: s.follow(pt(1300, 800)))])

        s = .pressed()
        s.drag(pt(951, 310), frame: before)
        s.drag(pt(952, 310), frame: before)
        s.drag(inside)
        s.drag(leftPoint)
        check("追跡: 諦めたあとは window を呼ばない", s.window.reads, 2)

        s = .pressed()
        s.drag(pt(910, 310), frame: before)
        s.drag(pt(920, 310), frame: before)
        check("追跡: 動いているか分からない間は drag のたびに window を読む", s.window.reads, 2)

        // 左の辺の近くを押して、ウィンドウが動かないまま左の辺へ 28 だけ動かす。
        let nearEdge = box(0, 690, 800, 600)
        s = .pressed(nearEdge, at: pt(30, 700))
        check("追跡: ウィンドウが動いていないうちは端に来ても preview しない", s.drag(leftPoint, frame: nearEdge), [])

        s = .pressed()
        s.drag(pt(910, 310), frame: before)
        check("追跡: 動かないまま端で離しても置かない", s.release(leftPoint), [])

        s = .pressed()
        check("追跡: 押しただけで端で離しても何も出さない", s.release(leftPoint), [])
    }

    // MARK: SnapTracker — ウィンドウが無い・押していない

    static func trackerNoWindow() {
        var s = Session()
        s.press(nil)
        check("追跡: ウィンドウの無いところで押したら drag は何も出さない", s.drag(leftPoint), [])

        s = Session()
        s.press(nil)
        s.drag(inside)
        s.drag(leftPoint)
        check("追跡: ウィンドウの無いところで押したら window を呼ばない", s.window.reads, 0)

        s = Session()
        s.press(nil)
        s.drag(leftPoint)
        check("追跡: ウィンドウの無いところで押したら端で離しても何も出さない", s.release(leftPoint), [])

        s = Session()
        s.press(nil)
        s.drag(leftPoint)
        check("追跡: ウィンドウの無いところで押したら Esc も何も出さない", s.cancel(), [])

        s = .pressed()
        check("追跡: 今の枠が読めなければ何も出さない", s.drag(inside, frame: nil), [])

        s = .pressed()
        s.drag(inside, frame: nil)
        check("追跡: 今の枠が読めなかったドラッグは、そのあと読めて動いていても何も出さない", s.drag(leftPoint), [])

        s = .pressed()
        s.drag(inside, frame: nil)
        s.drag(leftPoint)
        s.drag(topPoint)
        check("追跡: 今の枠が読めなかったあとは window を呼ばない", s.window.reads, 1)

        s = Session()
        check("追跡: 押していなければ drag は何も出さない", s.drag(leftPoint), [])

        s = Session()
        s.drag(inside)
        s.drag(leftPoint)
        check("追跡: 押していなければ window を呼ばない", s.window.reads, 0)

        s = Session()
        check("追跡: 押していなければ離しても何も出さない", s.release(leftPoint), [])

        s = Session()
        check("追跡: 押していなければ Esc も何も出さない", s.cancel(), [])
    }

    // MARK: SnapTracker — 動かしている間

    static func trackerMoving() {
        // ここが設計の判断: ウィンドウの枠を読むのは、動かしているかどうか分からないうちだけ。
        var s = Session.pressed()
        s.drag(inside)
        s.drag(inside2)
        s.drag(leftPoint)
        s.drag(topPoint)
        check("追跡: 動かしている間は window を呼ばない（読むのは動き出すまで）", s.window.reads, 1)

        s = .pressed()
        s.drag(leftPoint)
        check("追跡: 行き先が変わらない間は何も出さない（同じ辺の別の点）", s.drag(leftPoint2), [])

        s = .pressed()
        s.drag(leftPoint)
        check("追跡: 端から外れたら hidePreview", s.drag(inside), [.hidePreview])

        s = .pressed()
        s.drag(leftPoint)
        s.drag(inside)
        check("追跡: 外れたまま動いても何も出さない", s.drag(inside2), [])

        s = .pressed()
        s.drag(leftPoint)
        check("追跡: 端から別の端へ移ったら新しい preview だけ（hidePreview を挟まない）", s.drag(topLeftPoint), [.preview(topLeftSnap)])

        s = .pressed()
        s.drag(leftPoint)
        s.drag(inside)
        check("追跡: 外れてから同じ端に戻れば preview し直す", s.drag(leftPoint2), [.preview(leftSnap)])

        s = .pressed(screens: [mainScreen, rightScreen])
        s.drag(leftPoint)
        check("追跡: 別の画面の端へ移れば、その画面の行き先を preview",
              s.drag(pt(2562, 500)), [.preview(snapOn(rightScreen, .left, .firstThird))])

        s = .pressed(screens: [mainScreen, portraitScreen])
        s.drag(pt(2556, 700))
        check("追跡: 縦長の画面の端へ移れば hidePreview", s.drag(pt(2562, 500)), [.hidePreview])
    }

    // MARK: SnapTracker — 下の辺

    static func trackerBottom() {
        var s = Session.pressed()
        s.drag(bottomFirst)
        check("追跡: 下の辺で左の 1/3 から中央へ滑らせると左の 2/3", s.drag(bottomMiddle), [.preview(bottomSnap(.firstTwoThirds))])

        s = .pressed()
        s.drag(bottomFirst)
        s.drag(bottomMiddle)
        check("追跡: 中央にいる間は左の 2/3 のまま", s.drag(bottomMiddle2), [])

        s = .pressed()
        s.drag(bottomLast)
        check("追跡: 右の 1/3 から中央へ滑らせると右の 2/3", s.drag(bottomMiddle), [.preview(bottomSnap(.lastTwoThirds))])

        s = .pressed()
        s.drag(bottomFirst)
        s.drag(bottomMiddle)
        check("追跡: 左の 2/3 のまま右の 1/3 まで行くと右の 1/3", s.drag(bottomLast), [.preview(bottomSnap(.lastThird))])

        s = .pressed()
        s.drag(bottomFirst)
        s.drag(bottomMiddle)
        s.drag(bottomLast)
        check("追跡: 左から右まで滑らせて中央へ戻ると右の 2/3", s.drag(bottomMiddle2), [.preview(bottomSnap(.lastTwoThirds))])

        s = .pressed()
        check("追跡: 下の辺の中央から入れば中央の 1/3",
              s.drag(bottomMiddle), [.began(initial: before, current: s.follow(bottomMiddle)), .preview(bottomSnap(.centerThird))])

        s = .pressed()
        s.drag(bottomFirst)
        s.drag(inside)
        check("追跡: 下の辺から一度離れてから中央に来ると中央の 1/3", s.drag(bottomMiddle), [.preview(bottomSnap(.centerThird))])

        s = .pressed()
        s.drag(bottomFirst)
        s.drag(bottomLeftPoint)
        check("追跡: 左下の角から中央へ滑らせると中央の 1/3（角の操作では 2/3 にしない）",
              s.drag(bottomMiddle), [.preview(bottomSnap(.centerThird))])
    }

    // MARK: SnapTracker — 離す

    static func trackerRelease() {
        var s = Session.pressed()
        s.drag(leftPoint)
        check("追跡: 見せている端で離すと hidePreview に続けて place",
              s.release(leftPoint), [.hidePreview, .place(leftSnap, initial: before)])

        // ここが設計の判断: 元に戻す先の基準は動く前の枠（離した位置はたまたまカーソルがあった場所）。
        s = .pressed()
        s.drag(inside)
        s.drag(leftPoint)
        check("追跡: place の initial はドラッグ前の枠（began の current でも離したときの枠でもない）",
              places(s.release(leftPoint2)).map { $0.1 }, [before])

        s = .pressed()
        s.drag(inside)
        check("追跡: 見せていなくても離した点が端なら置く", s.release(leftPoint), [.place(leftSnap, initial: before)])

        s = .pressed()
        s.drag(leftPoint)
        check("追跡: 見せていても端の外で離せば置かない", s.release(inside), [.hidePreview])

        s = .pressed()
        s.drag(inside)
        check("追跡: 動かしていて端の外で離せば何も出さない", s.release(inside2), [])

        s = .pressed()
        s.drag(leftPoint)
        check("追跡: 離した点で決め直す（見せていたのと違う端で離せば、離した端に置く）",
              s.release(topPoint), [.hidePreview, .place(topSnap, initial: before)])

        s = .pressed()
        s.drag(bottomFirst)
        check("追跡: 左の 1/3 を見せたまま下の辺の中央で離すと左の 2/3 に置く",
              s.release(bottomMiddle), [.hidePreview, .place(bottomSnap(.firstTwoThirds), initial: before)])

        s = .pressed()
        s.drag(bottomFirst)
        s.drag(bottomMiddle)
        check("追跡: 左の 2/3 を見せたまま中央で離すと左の 2/3 に置く",
              s.release(bottomMiddle2), [.hidePreview, .place(bottomSnap(.firstTwoThirds), initial: before)])

        s = .pressed()
        s.drag(inside)
        check("追跡: 何も見せずに下の辺の中央で離すと中央の 1/3 に置く",
              s.release(bottomMiddle), [.place(bottomSnap(.centerThird), initial: before)])
    }

    // MARK: SnapTracker — 離したあと

    static func trackerAfterRelease() {
        var s = Session.pressed()
        s.drag(leftPoint)
        s.release(leftPoint)
        check("追跡: 離したあとは drag しても何も出さない", s.drag(topPoint), [])

        s = .pressed()
        s.drag(leftPoint)
        s.release(leftPoint)
        s.drag(topPoint)
        s.drag(inside)
        check("追跡: 離したあとは window を呼ばない", s.window.reads, 1)

        s = .pressed()
        s.drag(leftPoint)
        s.release(leftPoint)
        check("追跡: 2回続けて離しても2回目は何も出さない", s.release(leftPoint), [])

        s = .pressed()
        s.drag(leftPoint)
        s.release(leftPoint)
        check("追跡: 離したあとの Esc は何も出さない", s.cancel(), [])

        s = .pressed()
        s.drag(pt(910, 310), frame: before)
        s.release(pt(910, 310))
        check("追跡: 動き出す前に離したら、そのあとの drag は何も出さない（押していない状態に戻る）", s.drag(inside), [])

        // 左に置いたあと、別のウィンドウをまた左の辺へ運ぶ。前のドラッグで見せていたものは残っていない。
        let second = box(1500, 200, 600, 500)
        s = .pressed()
        s.drag(leftPoint)
        s.release(leftPoint)
        s.press(second, at: pt(1800, 210))
        check("追跡: 離したあとの押下は前と独立（同じ端でもまた preview する）",
              s.drag(leftPoint), [.began(initial: second, current: s.follow(leftPoint)), .preview(leftSnap)])

        s = .pressed()
        s.drag(leftPoint)
        s.press(second, at: pt(1800, 210))
        check("追跡: 離さずにもう一度押すと前のドラッグの状態は捨てる（同じ端でもまた preview する）",
              s.drag(leftPoint), [.began(initial: second, current: s.follow(leftPoint)), .preview(leftSnap)])

        s = Session()
        s.press(nil)
        s.drag(leftPoint)
        s.release(leftPoint)
        s.press(before)
        check("追跡: 相手にしないドラッグのあとでも、次の押下は相手にする",
              s.drag(inside), [.began(initial: before, current: s.follow(inside))])

        s = .pressed()
        s.drag(pt(951, 310), frame: before)
        s.press(second, at: pt(1800, 210))
        check("追跡: 諦めたドラッグのあと離さずに押し直しても相手にする",
              s.drag(inside), [.began(initial: second, current: s.follow(inside))])
    }

    // MARK: SnapTracker — Esc

    static func trackerCancel() {
        var s = Session.pressed()
        s.drag(leftPoint)
        check("追跡: 見せている間の Esc は hidePreview", s.cancel(), [.hidePreview])

        s = .pressed()
        s.drag(leftPoint)
        s.cancel()
        check("追跡: Esc のあとは端で離しても置かない", s.release(leftPoint), [])

        s = .pressed()
        s.drag(leftPoint)
        s.cancel()
        check("追跡: Esc のあとは端へ動いても何も出さない", s.drag(topPoint), [])

        s = .pressed()
        s.drag(leftPoint)
        s.cancel()
        s.drag(topPoint)
        s.drag(inside)
        check("追跡: Esc のあとは window を呼ばない", s.window.reads, 1)

        s = .pressed()
        s.drag(inside)
        check("追跡: 見せていないときの Esc は何も出さない", s.cancel(), [])

        s = .pressed()
        s.drag(inside)
        s.cancel()
        check("追跡: 見せていないときの Esc のあとも、端で離して置かない", s.release(leftPoint), [])

        s = .pressed()
        s.drag(leftPoint)
        s.cancel()
        check("追跡: 2回目の Esc は何も出さない", s.cancel(), [])

        s = .pressed()
        s.drag(pt(910, 310), frame: before)
        check("追跡: 動き出す前の Esc は何も出さない", s.cancel(), [])

        s = .pressed()
        s.drag(pt(910, 310), frame: before)
        s.cancel()
        check("追跡: 動き出す前の Esc は状態を変えない（そのあと動けば began）",
              s.drag(leftPoint), [.began(initial: before, current: s.follow(leftPoint)), .preview(leftSnap)])

        s = .pressed()
        s.drag(leftPoint)
        s.cancel()
        s.release(leftPoint)
        s.press(before)
        check("追跡: Esc したドラッグを離したあとの押下は相手にする",
              s.drag(leftPoint), [.began(initial: before, current: s.follow(leftPoint)), .preview(leftSnap)])
    }

    // MARK: 座標の入れ替え

    static func flipped() {
        check("flipped の例: AppKit の visible (0, 64, 2560, 1346) は AX の (0, 30, 2560, 1346)",
              box(0, 64, 2560, 1346).flipped(primaryHeight: 1440), box(0, 30, 2560, 1346))
        check("flipped の例: 主画面の真上 (0, 1440, 1920, 1080) は y が負",
              box(0, 1440, 1920, 1080).flipped(primaryHeight: 1440), box(0, -1080, 1920, 1080))
        check("flipped は AX から AppKit へも同じ式",
              box(0, 30, 2560, 1346).flipped(primaryHeight: 1440), box(0, 64, 2560, 1346))
        checkAll("flipped を2回かけると元に戻る", flipCases) { c in
            let (r, _, h) = c
            let back = r.flipped(primaryHeight: h).flipped(primaryHeight: h)
            return back == r ? nil : "\(show(r)) が \(show(back))（高さ \(num(h))）"
        }
        checkAll("flipped は x・幅・高さを変えない", flipCases) { c in
            let (r, _, h) = c
            let f = r.flipped(primaryHeight: h)
            return f.minX == r.minX && f.size == r.size ? nil : "\(show(r)) が \(show(f))"
        }
        checkAll("ScreenArea(cocoaFrame:…) は frame と visible を flipped と同じに変換する", flipCases) { c in
            let (frame, visible, h) = c
            let area = ScreenArea(cocoaFrame: frame, cocoaVisibleFrame: visible, primaryHeight: h)
            return area.frame == frame.flipped(primaryHeight: h) && area.visible == visible.flipped(primaryHeight: h) ? nil
                : "\(show(frame))・\(show(visible)) が \(show(area.frame))・\(show(area.visible))"
        }
    }

    // MARK: 元に戻す先（置いた場所にまだあるなら）

    static func restoreIfStillAt() {
        let first = box(100, 100, 800, 600) // 利用者が置いていた位置
        let leftHalf = box(0, 30, 1280, 1346)
        let rightHalf = box(1280, 30, 1280, 1346)
        let byHand = box(300, 200, 700, 500)

        check("戻す先: 記録していないキーは nil",
              WindowHistory<String>().restoreFrame(for: "safari", ifStillAt: leftHalf), nil)

        var h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        check("戻す先: 置いた枠のままなら戻す先", h.restoreFrame(for: "safari", ifStillAt: leftHalf), first)
        check("戻す先: 4つとも +1 ずれていても置いた場所にあるとみなす",
              h.restoreFrame(for: "safari", ifStillAt: box(1, 31, 1281, 1347)), first)
        check("戻す先: 4つとも -1 ずれていても置いた場所にあるとみなす",
              h.restoreFrame(for: "safari", ifStillAt: box(-1, 29, 1279, 1345)), first)
        let movedByTwo: [(String, CGRect)] = [
            ("x", box(2, 30, 1280, 1346)), ("y", box(0, 28, 1280, 1346)),
            ("幅", box(0, 30, 1282, 1346)), ("高さ", box(0, 30, 1280, 1344)),
        ]
        for (what, moved) in movedByTwo {
            check("戻す先: \(what) だけが 2 違えば nil（手で動かした・大きさを変えた）",
                  h.restoreFrame(for: "safari", ifStillAt: moved), nil)
        }
        check("戻す先: 1.5 違っても nil（1 以内でない）", h.restoreFrame(for: "safari", ifStillAt: box(1.5, 30, 1280, 1346)), nil)
        check("戻す先: 手で別の場所へ動かしていれば nil", h.restoreFrame(for: "safari", ifStillAt: byHand), nil)
        check("戻す先: 戻す先の位置にあっても nil（比べるのは置いた枠）", h.restoreFrame(for: "safari", ifStillAt: first), nil)
        check("戻す先: 別のキーの記録は見ない", h.restoreFrame(for: "mail", ifStillAt: leftHalf), nil)

        h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        _ = h.restoreFrame(for: "safari", ifStillAt: byHand)
        _ = h.restoreFrame(for: "safari", ifStillAt: box(1, 30, 1280, 1346))
        check("戻す先: ifStillAt を呼んでも restoreFrame(for:) は変わらない", h.restoreFrame(for: "safari"), first)

        h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        check("戻す先: ifStillAt は何度呼んでも同じ結果",
              [leftHalf, byHand, leftHalf, byHand, leftHalf].map { h.restoreFrame(for: "safari", ifStillAt: $0) },
              [first, nil, first, nil, first])

        h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        _ = h.restoreFrame(for: "safari", ifStillAt: box(1, 30, 1280, 1346))
        check("戻す先: 近い枠で呼んでも置いた枠は書き換わらない（x+1 で呼んだあとの x+2 は nil）",
              h.restoreFrame(for: "safari", ifStillAt: box(2, 30, 1280, 1346)), nil)

        h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        h.recordMove(of: "safari", from: leftHalf, to: rightHalf)
        check("戻す先: One で続けて置いたなら、最後に置いた枠で最初の位置", h.restoreFrame(for: "safari", ifStillAt: rightHalf), first)
        check("戻す先: One で続けて置いたなら、前に置いた枠ではもう nil", h.restoreFrame(for: "safari", ifStillAt: leftHalf), nil)

        h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        h.recordMove(of: "safari", from: byHand, to: rightHalf)
        check("戻す先: 手で動かしてから置いたなら、restoreFrame(for:) と同じく手で置いた位置",
              h.restoreFrame(for: "safari", ifStillAt: rightHalf), byHand)

        h = WindowHistory<String>()
        h.recordMove(of: "safari", from: first, to: leftHalf)
        h.forget("safari")
        check("戻す先: forget したキーは nil", h.restoreFrame(for: "safari", ifStillAt: leftHalf), nil)
    }

    // MARK: ドラッグで置いたときの元に戻す先

    static func dragHistory() {
        let a = box(100, 100, 800, 600)
        let b = box(0, 30, 1280, 1346) // 主画面の左半分
        let c = box(1280, 30, 1280, 1346) // 主画面の右半分
        let d = box(300, 200, 700, 500)

        var h = WindowHistory<String>()
        h.recordMove(of: "w", from: a, to: b)
        h.recordMove(of: "w", from: b, to: c)
        check("例: One で A → B に置いたあと B からドラッグで C に置いたら、戻す先は A のまま", h.restoreFrame(for: "w"), a)

        h = WindowHistory<String>()
        h.recordMove(of: "w", from: a, to: b)
        h.recordMove(of: "w", from: d, to: c)
        check("例: 手で D に動かしてからドラッグで C に置いたら、戻す先は D", h.restoreFrame(for: "w"), d)

        // トラッカーの place をそのまま recordMove に渡す（from = initial、to = snap.frame）。
        // 左半分 B にあるウィンドウを掴み、途中を経て右の辺で離す（右の 1/3 = (1707, 30, 853, 1346) に置く）。
        h = WindowHistory<String>()
        h.recordMove(of: "w", from: a, to: b)
        let s = Session.pressed(b, at: pt(640, 40))
        s.drag(pt(1000, 400))
        s.drag(pt(2558, 700))
        for (snap, initial) in places(s.release(pt(2558, 700))) {
            if let placed = snap.frame { h.recordMove(of: "w", from: initial, to: placed) }
        }
        check("place の initial を from に渡せば、One で置いたウィンドウをドラッグで置き直しても戻す先は A",
              h.restoreFrame(for: "w", ifStillAt: box(1707, 30, 853, 1346)), a)
    }
}
