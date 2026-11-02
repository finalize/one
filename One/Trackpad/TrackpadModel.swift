import Foundation

/// トラックパッドの端をなぞって、音量・画面の明るさ・キーボードの明るさを変える機能の状態。
///
/// 指を見張るのにも、キーを送るのにもアクセシビリティの許可が要る。許可が下りたら `trustGranted()` を
/// 呼ぶ（`AppModel` が許可を見ていて、`AppDelegate` がつなぐ）。
@Observable
final class TrackpadModel {
    /// 左右の端をなぞって、音量（右）と画面の明るさ（左）を変えるか。
    ///
    /// 既定は true。ふつうにポインタを動かすつもりの指を取り違えるようなら、ここで切れる。
    var adjustsWithEdges = true {
        didSet {
            guard adjustsWithEdges != oldValue else { return }
            UserDefaults.standard.set(adjustsWithEdges, forKey: Self.adjustsWithEdgesKey)
            update()
        }
    }

    /// 上の端をなぞって、キーボードの明るさを変えるか。
    ///
    /// 既定は true。左右の端とは別に切れるようにしてある。上の端は、キーボードから手を下ろして
    /// 横にポインタを動かす指と取り違えやすいのと、バックライトの無いキーボードでは何も起きないから。
    var adjustsKeyboardWithTopEdge = true {
        didSet {
            guard adjustsKeyboardWithTopEdge != oldValue else { return }
            UserDefaults.standard.set(adjustsKeyboardWithTopEdge, forKey: Self.adjustsKeyboardWithTopEdgeKey)
            update()
        }
    }

    private static let adjustsWithEdgesKey = "adjustsWithTrackpadEdges"
    private static let adjustsKeyboardWithTopEdgeKey = "adjustsKeyboardWithTrackpadTopEdge"

    private let watcher = EdgeSlideWatcher()
    /// アクセシビリティの許可が下りたか。下りるまで見張らない。
    private var isTrusted = false

    init() {
        // `bool(forKey:)` は、一度も保存していないときも false を返す。既定を true に
        // したいので、「保存していない」を見分けられる `object(forKey:)` で読む。
        adjustsWithEdges = UserDefaults.standard.object(forKey: Self.adjustsWithEdgesKey) as? Bool ?? true
        adjustsKeyboardWithTopEdge = UserDefaults.standard.object(forKey: Self.adjustsKeyboardWithTopEdgeKey) as? Bool ?? true
    }

    /// アクセシビリティの許可が下りた。設定に合わせて見張りを始める。
    func trustGranted() {
        isTrusted = true
        update()
    }

    /// 設定と許可に合わせて、相手にする端を決め、見張りを始める・やめる。どの端も切ってあれば見張らない。
    private func update() {
        var edges: Set<TrackpadEdge> = []
        if adjustsWithEdges { edges.formUnion([.left, .right]) }
        if adjustsKeyboardWithTopEdge { edges.insert(.top) }
        watcher.edges = edges
        if !edges.isEmpty && isTrusted {
            watcher.start()
        } else {
            watcher.stop()
        }
    }
}
