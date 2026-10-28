import Carbon
import Foundation

/// 入力ソース（英数 / ひらがな など）1つ分。
///
/// macOS の入力ソース API は Carbon 時代の C の API で、名前は TIS
/// （Text Input Sources）で始まる。値は CoreFoundation の型で返ってきて、
/// Swift からは `Unmanaged` 経由でしか取り出せない。その面倒さをこの型に閉じ込めて、
/// 呼ぶ側は `InputSource.current?.languages` くらいで済むようにしている。
struct InputSource {
    /// TIS が扱う生のオブジェクト。プロパティを読むときにそのまま渡す。
    let raw: TISInputSource

    /// "com.apple.keylayout.ABC" のような一意な ID。
    let id: String
    /// 「ABC」「ひらがな」など、システム設定に出るのと同じ表示名。
    let localizedName: String
    /// キーボードレイアウト（ABC など）か、入力モード（ひらがな など）か。
    let type: String
    /// その入力ソースが扱う言語コード。かな側を見つけるのに使う。
    let languages: [String]

    /// 生のオブジェクトから組み立てる。
    ///
    /// 戻り値が `InputSource?` で、`init?` は「失敗しうる初期化」。ID が取れない
    /// ソースは使いようが無いので `nil` を返す。Swift では「失敗」を例外ではなく
    /// Optional で返すことが多い。
    init?(raw: TISInputSource) {
        guard let id = Self.string(raw, kTISPropertyInputSourceID) else { return nil }
        self.raw = raw
        self.id = id
        self.localizedName = Self.string(raw, kTISPropertyLocalizedName) ?? id
        self.type = Self.string(raw, kTISPropertyInputSourceType) ?? ""
        self.languages = Self.strings(raw, kTISPropertyInputSourceLanguages)
    }

    /// いま実際に選べる状態か（システム設定で有効になっていて、選択対象になれる）。
    var isSelectable: Bool {
        Self.bool(raw, kTISPropertyInputSourceIsSelectCapable)
            && Self.bool(raw, kTISPropertyInputSourceIsEnabled)
    }

    // MARK: - 切り替え

    /// JIS キーボードの 英数 / かな キーを押したことにして、前面のアプリに切り替えさせる。
    /// キーを作れたら true。
    ///
    /// `TISSelectInputSource` で選ぶのはやめた。あれはシステムの選択を書き換えるだけで、
    /// 前面のアプリには通知で知らせるだけ。Muse はその通知を拾わず、システムは「ひらがな」
    /// （カーソルの横にも「あ」が出る）なのに、入力欄は英字のまま残った。システムからは既に
    /// ひらがななので、何度選び直しても何も起きない。フォーカスを外して戻すまで直らない。
    ///
    /// キーは前面のアプリに届き、アプリの入力欄が自分で入力モードを替える。本物の JIS キーボードと
    /// 同じ道なので取り残されない。どの入力ソースに行くかは macOS と日本語入力が決める。
    /// イベントを送るにはアクセシビリティの許可が要るが、⌘ を見張るのに既に持っている。
    static func pressJISKey(kana: Bool) -> Bool {
        let code = CGKeyCode(kana ? kVK_JIS_Kana : kVK_JIS_Eisu)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - 一覧と現在値

    /// システムが知っている入力ソース全部。
    static var all: [InputSource] {
        let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]
        // compactMap は map したうえで nil を落とす。init? と組み合わせると気持ちよく書ける。
        return (list ?? []).compactMap(InputSource.init(raw:))
    }

    /// いま選ばれている入力ソース。
    static var current: InputSource? {
        guard let raw = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return InputSource(raw: raw)
    }

    // MARK: - 英数 / かな の解決

    /// 英数側として設定の窓に出す入力ソースを探す。
    ///
    /// 切り替えは英数キーで行い、行き先は macOS が決める（`pressJISKey`）。ここで探すのは、
    /// 行くはずの先を見せるためだけ。ABC と ひらがな の環境で、実際の行き先と一致するのを確かめた。
    ///
    /// ID を決め打ちにしない。US 配列の人は `com.apple.keylayout.US` だし、
    /// ABC を無効にしている人もいる。「有効なキーボードレイアウトのうち、
    /// 好みの順で最初に見つかったもの」にしておけば環境に依らず動く。
    static func resolveASCII() -> InputSource? {
        let layouts = all.filter { $0.isSelectable && $0.type == (kTISTypeKeyboardLayout as String) }
        let preferred = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.USExtended",
            "com.apple.keylayout.British",
        ]
        for id in preferred {
            if let hit = layouts.first(where: { $0.id == id }) { return hit }
        }
        // どれも無ければ、日本語以外のレイアウトを1つ。それも無ければ先頭。
        return layouts.first { !$0.languages.contains("ja") } ?? layouts.first
    }

    /// かな側として設定の窓に出す入力ソースを探す。見つからなければ、かなキーを送っても行き先が無い。
    ///
    /// 「入力モードであって、日本語を扱うもの」という条件で探す。こうしておくと
    /// ことえりでも Google 日本語入力でも ATOK でも同じコードで引っかかる。
    static func resolveKana() -> InputSource? {
        all.first {
            $0.isSelectable
                && $0.type == (kTISTypeKeyboardInputMode as String)
                && $0.languages.contains("ja")
        }
    }

    // MARK: - C の API から値を取り出す部分

    /// TIS のプロパティを文字列として読む。
    ///
    /// `TISGetInputSourceProperty` は型の情報を持たない生ポインタを返すので、
    /// 「これは CFString のはず」と自分で宣言して受け取る。`takeUnretainedValue` は
    /// 「所有権はこちらに移らない（解放の責任を持たない）」という意味。
    /// 対になる `takeRetainedValue` は「所有権を受け取る＝自分が解放する側」。
    /// C の API を触るときはこの2つの選択を毎回間違えないようにする。
    private static func string(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func bool(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    private static func strings(_ src: TISInputSource, _ key: CFString) -> [String] {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
    }
}
