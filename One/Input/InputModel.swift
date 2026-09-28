import AppKit
import Carbon

/// 左右の ⌘ で英かなを切り替える機能の状態。今のモード、英数側・かな側の入力ソース、設定。
///
/// ⌘ の単独押しを見張るにはアクセシビリティの許可が要る。許可が下りたら `startWatching()` を呼ぶ
/// （`AppModel` が許可を見ていて、`AppDelegate` がつなぐ）。`@Observable` と `private(set)` の意味は
/// `AppModel` の注釈に書いた。
@Observable
final class InputModel {
    /// いまの入力モードが日本語（かな）かどうか。メニューバーの文字はこれで決まる。
    private(set) var isKana = false

    /// 英数側・かな側として実際に使う入力ソースの表示名。設定の窓に出す。
    private(set) var asciiName = "—"
    private(set) var kanaName = "—"

    /// 左右の割り当てを入れ替えるか。
    ///
    /// `didSet` はプロパティが変わった直後に走る。UI から変えられた値を
    /// そのまま UserDefaults（macOS の設定保存先。ブラウザの localStorage 的なもの）
    /// に書いておくと、次の起動でも保たれる。
    var isSwapped = false {
        didSet { UserDefaults.standard.set(isSwapped, forKey: Self.swapKey) }
    }

    /// メニューバーに現在のモード（A / あ）も並べるか。
    ///
    /// 既定は false。macOS 自身の入力メニューが既にメニューバーに A / あ を出して
    /// いることが多く、その隣に同じものを出しても二重になるだけだから。
    /// システムの入力メニューを消している人は true にすると状態が見えるようになる。
    var showsMode = false {
        didSet { UserDefaults.standard.set(showsMode, forKey: Self.showsModeKey) }
    }

    /// メニューバーに出す1文字。
    ///
    /// 計算プロパティ（computed property）。値を持たず、読まれるたびに評価される。
    /// `isKana` を読んでいるので、`isKana` が変わればこれを使っている画面も更新される。
    var menuBarLabel: String { isKana ? "あ" : "A" }

    private static let swapKey = "swapSides"
    private static let showsModeKey = "showsModeInMenuBar"

    private let watcher = CommandKeyWatcher()
    private var ascii: InputSource?
    private var kana: InputSource?

    init() {
        isSwapped = UserDefaults.standard.bool(forKey: Self.swapKey)
        showsMode = UserDefaults.standard.bool(forKey: Self.showsModeKey)

        reloadInputSources()
        refreshCurrentMode()

        // 単独押しが来たときにやることを渡す。
        watcher.onTap = { [weak self] side in
            self?.switchInput(for: side)
        }

        // 入力ソースが変わったらメニューバーの文字を合わせる。
        // 入力の切り替えは他のプロセス（入力メソッド）が行うので、通知も
        // プロセスを越えて飛んでくる。だから NotificationCenter ではなく
        // DistributedNotificationCenter で受ける。
        //
        // この通知は1回の切り替えで何度も届く（実測で2〜4回）。なので受け取った側は
        // 何度呼ばれても同じ結果になる処理だけを置く。
        observe(kTISNotifySelectedKeyboardInputSourceChanged) { [weak self] in
            self?.refreshCurrentMode()
        }

        // 「どの入力ソースが有効か」が変わったときは別の通知が来る。
        // 一覧の作り直しは重いので、必要なこちらだけに繋いでおく。
        observe(kTISNotifyEnabledKeyboardInputSourcesChanged) { [weak self] in
            self?.reloadInputSources()
        }

        log.notice("起動した 英数=\(self.asciiName, privacy: .public) かな=\(self.kanaName, privacy: .public)")
    }

    /// ⌘ の見張りを始める。アクセシビリティの許可が下りてから呼ぶ（無いと黙って何も届かない）。
    func startWatching() {
        watcher.start()
    }

    /// TIS の通知を受け取る。名前が C の定数なので変換をここでまとめている。
    private func observe(_ name: CFString, _ handler: @escaping () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(name as String),
            object: nil,
            queue: .main
        ) { _ in handler() }
    }

    // MARK: - 切り替え

    /// 単独押しされた側に応じて入力を切り替える。
    private func switchInput(for side: CommandSide) {
        // 右がかな、左が英数。入れ替え設定が入っていれば逆。
        // `!=` を Bool 同士に使うと排他的論理和（XOR）になる。
        let wantKana = (side == .right) != isSwapped
        let target = wantKana ? kana : ascii
        let ok = target?.select() ?? false
        // うまくいっているときは debug（残さない）、失敗したときだけ error（残す）。
        // 「たまに切り替わらない」を後から追えるようにしておきたいのは失敗の方だけ。
        if ok {
            log.debug("切り替え \(wantKana ? "かな" : "英数", privacy: .public) 対象=\(target?.id ?? "なし", privacy: .public)")
        } else {
            log.error("切り替えに失敗 \(wantKana ? "かな" : "英数", privacy: .public) 対象=\(target?.id ?? "見つからない", privacy: .public)")
        }
    }

    /// 英数側・かな側に使う入力ソースを拾い直す。
    private func reloadInputSources() {
        ascii = InputSource.resolveASCII()
        kana = InputSource.resolveKana()
        asciiName = ascii?.localizedName ?? "見つかりません"
        kanaName = kana?.localizedName ?? "見つかりません"
    }

    /// いまの入力ソースを見て `isKana` を合わせる。
    private func refreshCurrentMode() {
        guard let current = InputSource.current else { return }
        // ID の一致ではなく「日本語を扱う入力モードか」で見る。ことえりでも
        // 他の IME でも同じ判定で通る。
        // 変数名を kana にしないこと。プロパティの `kana`（InputSource?）を
        // この関数の中だけ Bool で隠してしまう。Swift は警告を出さない。
        let nowKana = current.type == (kTISTypeKeyboardInputMode as String)
            && current.languages.contains("ja")
        // 同じ値でも代入すると @Observable は変化として扱い、画面を描き直させる。
        // この通知は何度も届くので、変わったときだけ書く。
        if nowKana != isKana { isKana = nowKana }
    }
}
