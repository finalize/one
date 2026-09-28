import CoreGraphics

/// 「元に戻す」のために、One が動かす前の枠をウィンドウごとに覚えておく。
///
/// 覚えるのは「One が最初に動かす直前の枠」。左半分 → 右 1/3 → 最大化 と続けて
/// 動かしてから元に戻すと、左半分ではなく最初の位置に戻る（Rectangle と同じ）。
///
/// ただし、One が置いたあとに利用者が手でウィンドウを動かしていたら、そこを新しい
/// 出発点として覚え直す。手で整えた位置を One の操作で崩しても、戻ってこられるように。
/// 手で動かしたかどうかは、いまの枠が One が最後に置いた枠と同じかどうかで見る。
///
/// ウィンドウをどう見分けるかは `Key` に任せる（アプリでは `AXUIElement`）。
/// 型を決めずにおくと、テストでは `Int` を渡して試せる。
struct WindowHistory<Key: Equatable> {
    private struct Entry {
        let key: Key
        /// 元に戻す先。
        let restore: CGRect
        /// One が最後に置いた枠。手で動かされたかを見分けるのに使う。
        let placed: CGRect
    }

    /// 覚えておくウィンドウの数。
    ///
    /// 閉じたウィンドウの分は誰も消してくれないので、常駐しているうちに溜まり続ける。
    /// 古いものから捨てる。
    let limit: Int

    /// 最近動かしたものほど後ろ。
    private var entries: [Entry] = []

    init(limit: Int = 50) {
        self.limit = limit
    }

    /// 元に戻す先。One がまだ動かしていないウィンドウなら nil。
    func restoreFrame(for key: Key) -> CGRect? {
        entries.last { $0.key == key }?.restore
    }

    /// One が置いた場所にまだあるなら、元に戻す先。
    ///
    /// スナップしたウィンドウをドラッグで引き剥がしたときに、元の大きさへ戻すのに使う。
    /// One が置いたあとに手で動かしたり大きさを変えたりしていたら、もうスナップしている
    /// とは言えないので nil。
    func restoreFrame(for key: Key, ifStillAt frame: CGRect) -> CGRect? {
        guard let entry = entries.last(where: { $0.key == key }), Self.same(entry.placed, frame) else { return nil }
        return entry.restore
    }

    /// One がウィンドウを動かしたことを記録する。
    ///
    /// - Parameters:
    ///   - current: 動かす直前の枠。ドラッグで端へ寄せて置いたときは、ドラッグを始める前の枠
    ///     （離した位置はカーソルがたまたまあった場所で、戻り先として意味が無い）
    ///   - placed: 動かしたあとに実際に読み取った枠（指示した枠ではなく）
    mutating func recordMove(of key: Key, from current: CGRect, to placed: CGRect) {
        // 前に One が置いた場所から動いていなければ、最初の出発点を引き継ぐ。
        // 初めて動かすか、手で動かされていたら、いまの枠が新しい出発点。
        let restore: CGRect
        if let previous = entries.last(where: { $0.key == key }), Self.same(previous.placed, current) {
            restore = previous.restore
        } else {
            restore = current
        }

        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, restore: restore, placed: placed))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// 覚えていた枠を捨てる。元に戻したあとに呼ぶ。
    mutating func forget(_ key: Key) {
        entries.removeAll { $0.key == key }
    }

    /// 同じ枠か。
    ///
    /// アプリによっては読み返した位置が小数になったり、1pt ずれて返ってきたりする。
    /// そのくらいは同じとみなさないと、何もしていないのに「手で動かした」ことになる。
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
