import AppKit
import ApplicationServices
import ServiceManagement

/// アプリ全体の状態。アクセシビリティの許可、ログイン項目、⌘ の左クリックの割り当て。
///
/// 機能ごとの状態は、それぞれの Model にある（英かなは `InputModel`、ウィンドウは `WindowModel`、
/// 鏡は `MirrorModel`、カレンダーは `CalendarModel`、モニタは `MonitorModel`）。
///
/// `@Observable` を付けると、この class のプロパティを読んだ View が
/// そのプロパティが変わったときだけ描き直される。React の state + 再レンダリングに
/// 近いが、依存配列を自分で書く必要は無い。読んだ事実から自動で追跡される。
///
/// `struct` ではなく `class` にしているのは、状態は「1つの実体を共有したい」もので、
/// コピーされてほしくないから。Swift の struct は代入するたびにコピーされる
/// （Go の構造体と同じ値型）。class は参照型で、Go のポインタに近い。
@Observable
final class AppModel {
    /// アクセシビリティ（キー入力を見る・ほかのアプリのウィンドウを動かす許可）が下りているか。
    ///
    /// `private(set)` は「読むのは誰でも、書けるのはこの型の中だけ」。
    /// 状態の変更経路を1か所に絞れるので、UI から勝手に書き換えられなくなる。
    private(set) var isTrusted = false

    /// 許可が下りたとき（起動したときにもう下りていたときも）に呼ばれる。
    /// ⌘ の見張り（`InputModel`）とドラッグの見張り（`WindowModel`）を始める合図。
    var onTrusted: (() -> Void)?

    /// メニューバーの ⌘ の左クリックでカレンダーを出すか。
    ///
    /// 既定は true（左クリックでカレンダー、右クリックでメニュー）。false なら逆になる。
    /// よく使うほうを左に置けるように、設定の窓の「カレンダー」タブで入れ替えられる。
    var leftClickShowsCalendar = true {
        didSet {
            guard leftClickShowsCalendar != oldValue else { return }
            UserDefaults.standard.set(leftClickShowsCalendar, forKey: Self.leftClickShowsCalendarKey)
        }
    }

    /// ログイン時に起動するか。
    ///
    /// 値を UserDefaults に持たず、毎回 `SMAppService` に聞く。システム設定の
    /// 「ログイン項目」側で外されることがあるから。
    ///
    /// 自分で持っていない値なので、`@Observable` は変わったことに気づけない。
    /// 「読んだ」「変えた」を `access` / `withMutation` で手で伝える。どちらも
    /// `@Observable` がこの class に足しているもので、ふつうのプロパティなら裏で呼ばれている。
    var launchesAtLogin: Bool {
        get {
            access(keyPath: \.launchesAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchesAtLogin) {
                setLaunchesAtLogin(newValue)
            }
        }
    }

    private static let leftClickShowsCalendarKey = "leftClickShowsCalendar"

    private var trustTimer: Timer?
    /// 許可の状態を一度でも見たか。
    ///
    /// 起動直後の1回だけやりたいことが2つある。状態をログに必ず1行残すことと、
    /// 許可が無ければダイアログを出すこと。どちらも「初回かどうか」で決まるので
    /// このフラグ1つで見ているが、名前はログ側に寄せない（実際そう書いていて、
    /// ダイアログが出る条件がログ用の名前の裏に隠れていた）。
    private var hasCheckedTrust = false

    init() {
        // `bool(forKey:)` は、一度も保存していないときも false を返す。既定を true に
        // したいので、「保存していない」を見分けられる `object(forKey:)` で読む。
        leftClickShowsCalendar = UserDefaults.standard.object(forKey: Self.leftClickShowsCalendarKey) as? Bool ?? true
    }

    // MARK: - 許可

    /// 許可の状態を見始める。`onTrusted` をつないでから呼ぶ（もう下りていれば、すぐに呼ばれる）。
    func startCheckingTrust() {
        updateTrust()
    }

    /// 許可を求めるダイアログを出す。
    ///
    /// これを呼ぶと、macOS が「One がコンピュータの制御を求めています」という
    /// ダイアログを出し、**同時にアクセシビリティの一覧にこのアプリを登録する**。
    /// 登録さえされていれば、ユーザーはスイッチを入れるだけでよく、
    /// `.app` の場所を自分で探して「+」で追加する必要が無い。
    ///
    /// ダイアログはアプリごとに一度しか出ない。一度断られたあとに出したいときは
    /// `tccutil reset Accessibility com.finalize.one` で記録を消す。
    func promptForAccessibility() {
        // kAXTrustedCheckOptionPrompt は CFString の定数。Unmanaged で包まれて
        // いるので、いったん取り出してから辞書のキーとして使う。
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        log.notice("許可ダイアログを出した")
    }

    /// システム設定のアクセシビリティのページを開く。
    func openAccessibilitySettings() {
        promptForAccessibility()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 許可の状態を見に行く。下りていたら `onTrusted` を呼ぶ。
    ///
    /// 許可はユーザーがシステム設定で与えるもので、「与えられた瞬間」を知らせる通知が
    /// 用意されていない。なので下りるまで1秒ごとに見に行き、下りたらタイマーを止める。
    private func updateTrust() {
        let trusted = AXIsProcessTrusted()
        let isFirstCheck = !hasCheckedTrust
        hasCheckedTrust = true

        // 起動直後は必ず1行残す。ログが出ないことと許可が無いことを区別できないと、
        // 動かないときに何も分からなくなる。
        if trusted != isTrusted || isFirstCheck {
            log.notice("アクセシビリティ許可: \(trusted ? "あり" : "なし", privacy: .public)")
            isTrusted = trusted
        }

        // 起動して最初に見たときに許可が無ければ、こちらからダイアログを出す。
        // 一覧に登録される副作用が本命で、これが無いとユーザーは .app を
        // 自分で探して「+」で追加することになる。
        if isFirstCheck && !trusted {
            promptForAccessibility()
        }

        if trusted {
            onTrusted?()
            trustTimer?.invalidate()
            trustTimer = nil
        } else if trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updateTrust()
            }
        }
    }

    // MARK: - ログイン項目

    /// ログイン項目に入れる・外す。
    ///
    /// アプリの置き場所ごと登録される。`/Applications/One.app` から起動したものでやること
    /// （DerivedData の中のものを登録すると、ビルドし直したときに迷子になる）。
    private func setLaunchesAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            log.notice("ログイン時に起動: \(String(describing: service.status), privacy: .public)")
        } catch {
            log.error("ログイン項目を変えられなかった: \(error.localizedDescription, privacy: .public)")
        }
        // システム設定で「許可」を押すまで入らない場合がある。そのときは設定を開いて見せる。
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
