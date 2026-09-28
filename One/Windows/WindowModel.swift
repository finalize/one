import AppKit

/// ウィンドウを並べる機能の状態。ショートカットとドラッグの設定と、並べる手順への入口。
///
/// ドラッグの見張りにはアクセシビリティの許可が要る。許可が下りたら `trustGranted()` を呼ぶ
/// （`AppModel` が許可を見ていて、`AppDelegate` がつなぐ）。
@Observable
final class WindowModel {
    /// ショートカット（⌃⌥← など）でウィンドウを動かすか。
    ///
    /// 既定は true。Rectangle のような他のウィンドウ整理アプリと一緒に使うときに、
    /// One 側だけ止められるようにしてある。メニューから選んで動かすのは、これを
    /// 切っていてもできる。
    ///
    /// `@Observable` のクラスでは、init の中で代入しても `didSet` が走る（試して確かめた）。
    /// 同じ値の代入でショートカットを登録し直さないように、変わったときだけにしている。
    var arrangesWindows = true {
        didSet {
            guard arrangesWindows != oldValue else { return }
            UserDefaults.standard.set(arrangesWindows, forKey: Self.arrangesWindowsKey)
            updateHotKeys()
        }
    }

    /// ウィンドウをドラッグで画面の端へ寄せたら並べるか。
    ///
    /// 既定は true。macOS 15 からは macOS 自身にも端へ寄せて並べる機能があり
    /// （システム設定 > デスクトップと Dock）、両方が入っていると1回のドラッグに
    /// 両方が反応する。そちらを使うなら、こちらを切る。
    var snapsWindows = true {
        didSet {
            guard snapsWindows != oldValue else { return }
            UserDefaults.standard.set(snapsWindows, forKey: Self.snapsWindowsKey)
            updateSnapping()
        }
    }

    private static let arrangesWindowsKey = "arrangesWindows"
    private static let snapsWindowsKey = "snapsWindows"

    private let hotKeys = HotKeys()
    /// ショートカットとスナップの両方が、同じ1つを使う。「元に戻す」の記録を共有するため。
    private let arranger: WindowArranger
    private let snapper: DragSnapper
    /// アクセシビリティの許可が下りたか。ドラッグの見張りは、下りるまで始めない。
    private var isTrusted = false

    init() {
        // 初期値を書いていないプロパティは、self を使う前（ほかのプロパティに代入するより前）
        // に埋めておく必要がある。スナップ役に同じ arranger を渡したいので、ここで作る。
        let arranger = WindowArranger()
        self.arranger = arranger
        snapper = DragSnapper(arranger: arranger)

        // `bool(forKey:)` は、一度も保存していないときも false を返す。既定を true に
        // したいので、「保存していない」を見分けられる `object(forKey:)` で読む。
        arrangesWindows = UserDefaults.standard.object(forKey: Self.arrangesWindowsKey) as? Bool ?? true
        snapsWindows = UserDefaults.standard.object(forKey: Self.snapsWindowsKey) as? Bool ?? true

        // ウィンドウのショートカットが押されたら動かす。メニューから選んだときと同じ道を通る。
        hotKeys.onPress = { [weak self] action in
            self?.arrange(action)
        }
        updateHotKeys()
    }

    /// アクセシビリティの許可が下りた。設定に合わせてドラッグの見張りを始める。
    func trustGranted() {
        isTrusted = true
        updateSnapping()
    }

    /// 手前のウィンドウに操作を行う。ショートカットからもメニューからもここを通る。
    func arrange(_ action: WindowAction) {
        arranger.perform(action)
    }

    /// 設定に合わせて、ウィンドウのショートカットを登録する・外す。
    ///
    /// 登録そのものにはアクセシビリティの許可は要らないので、許可を待たずに登録する。
    /// 許可が無いうちに押されたら、動かすほうでビープを鳴らして知らせる。
    private func updateHotKeys() {
        if arrangesWindows {
            hotKeys.register(WindowAction.allCases)
        } else {
            hotKeys.unregisterAll()
        }
    }

    /// 設定と許可に合わせて、ドラッグの見張りを始める・やめる。
    ///
    /// こちらはショートカットと違い、許可が下りるまで始めない。押した場所のウィンドウを
    /// 調べるのにも、置くのにも許可が要るので、許可が無いうちに見張っても何もできない。
    private func updateSnapping() {
        if snapsWindows && isTrusted {
            snapper.start()
        } else {
            snapper.stop()
        }
    }
}
