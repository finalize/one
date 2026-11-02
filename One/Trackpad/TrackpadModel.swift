import Foundation

/// トラックパッドの端をなぞって、音量とキーボードの明るさを変える機能の状態。
///
/// 指を見張るのにも、キーを送るのにもアクセシビリティの許可が要る。許可が下りたら `trustGranted()` を
/// 呼ぶ（`AppModel` が許可を見ていて、`AppDelegate` がつなぐ）。
@Observable
final class TrackpadModel {
    /// 端をなぞって、音量（右）とキーボードの明るさ（左）を変えるか。
    ///
    /// 既定は true。ふつうにポインタを動かすつもりの指を取り違えるようなら、ここで切れる。
    var adjustsWithEdges = true {
        didSet {
            guard adjustsWithEdges != oldValue else { return }
            UserDefaults.standard.set(adjustsWithEdges, forKey: Self.adjustsWithEdgesKey)
            update()
        }
    }

    private static let adjustsWithEdgesKey = "adjustsWithTrackpadEdges"

    private let watcher = EdgeSlideWatcher()
    /// アクセシビリティの許可が下りたか。下りるまで見張らない。
    private var isTrusted = false

    init() {
        // `bool(forKey:)` は、一度も保存していないときも false を返す。既定を true に
        // したいので、「保存していない」を見分けられる `object(forKey:)` で読む。
        adjustsWithEdges = UserDefaults.standard.object(forKey: Self.adjustsWithEdgesKey) as? Bool ?? true
    }

    /// アクセシビリティの許可が下りた。設定に合わせて見張りを始める。
    func trustGranted() {
        isTrusted = true
        update()
    }

    /// 設定と許可に合わせて、見張りを始める・やめる。
    private func update() {
        if adjustsWithEdges && isTrusted {
            watcher.start()
        } else {
            watcher.stop()
        }
    }
}
