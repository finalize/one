import Carbon
import Foundation

/// 入力ソース（英数 / ひらがな など）1つ分。
///
/// macOS の入力ソース API は Carbon 時代の C の API で、名前は TIS
/// （Text Input Sources）で始まる。値は CoreFoundation の型で返ってきて、
/// Swift からは `Unmanaged` 経由でしか取り出せない。その面倒さをこの型に閉じ込めて、
/// 呼ぶ側は `InputSource.ascii?.select()` くらいで済むようにしている。
struct InputSource {
    /// TIS が扱う生のオブジェクト。切り替えるときにそのまま渡す。
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

    /// この入力ソースに切り替える。成功したら true。
    ///
    /// `@discardableResult` は「戻り値を使わなくても警告を出さない」という指定。
    /// Swift は既定で戻り値の無視を警告するので、こう書いて許可しておく。
    @discardableResult
    func select() -> Bool {
        TISSelectInputSource(raw) == noErr
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

    /// 英数側として使う入力ソースを決める。
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

    /// かな側として使う入力ソースを決める。
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
