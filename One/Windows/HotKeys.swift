import AppKit
import Carbon
import SwiftUI

/// ショートカット1つ分。
struct Shortcut {
    /// 押すキーの**物理的な位置**（Carbon の仮想キーコード `kVK_*`）。
    ///
    /// 文字ではなく位置で決める。One は入力ソースを切り替えるアプリなので、
    /// 「U の文字が出るキー」で決めると、入力ソースによって効いたり効かなかったりしかねない。
    let keyCode: Int
    /// メニューに出す表記。
    let key: KeyEquivalent
    /// Carbon にも同じ名前の型（中身はただの整数）があるので、SwiftUI のほうだと明示する。
    let modifiers: SwiftUI.EventModifiers

    /// Carbon の API が受け取る形の修飾キー。
    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }

    /// `NSMenuItem` が受け取る形の修飾キー。メニューの項目の右にキーを出すのに使う。
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension WindowAction {
    /// 既定のショートカット。Rectangle の既定（Spectacle 式ではないほう）と同じ。
    ///
    /// ⌃⌥ を基本にしているのは、アプリのメニューにまず使われていない組み合わせだから。
    /// ⌘ を含むもの（前の画面へ・次の画面へ）も、⌃⌥ と一緒に押すので ⌘ の単独押しには
    /// ならず、英かなは切り替わらない。
    var shortcut: Shortcut {
        let co: SwiftUI.EventModifiers = [.control, .option]
        switch self {
        case .leftHalf: return Shortcut(keyCode: kVK_LeftArrow, key: .leftArrow, modifiers: co)
        case .rightHalf: return Shortcut(keyCode: kVK_RightArrow, key: .rightArrow, modifiers: co)
        case .topHalf: return Shortcut(keyCode: kVK_UpArrow, key: .upArrow, modifiers: co)
        case .bottomHalf: return Shortcut(keyCode: kVK_DownArrow, key: .downArrow, modifiers: co)
        case .topLeft: return Shortcut(keyCode: kVK_ANSI_U, key: "u", modifiers: co)
        case .topRight: return Shortcut(keyCode: kVK_ANSI_I, key: "i", modifiers: co)
        case .bottomLeft: return Shortcut(keyCode: kVK_ANSI_J, key: "j", modifiers: co)
        case .bottomRight: return Shortcut(keyCode: kVK_ANSI_K, key: "k", modifiers: co)
        case .firstThird: return Shortcut(keyCode: kVK_ANSI_D, key: "d", modifiers: co)
        case .centerThird: return Shortcut(keyCode: kVK_ANSI_F, key: "f", modifiers: co)
        case .lastThird: return Shortcut(keyCode: kVK_ANSI_G, key: "g", modifiers: co)
        case .firstTwoThirds: return Shortcut(keyCode: kVK_ANSI_E, key: "e", modifiers: co)
        case .centerTwoThirds: return Shortcut(keyCode: kVK_ANSI_R, key: "r", modifiers: co)
        case .lastTwoThirds: return Shortcut(keyCode: kVK_ANSI_T, key: "t", modifiers: co)
        case .maximize: return Shortcut(keyCode: kVK_Return, key: .return, modifiers: co)
        case .maximizeHeight: return Shortcut(keyCode: kVK_UpArrow, key: .upArrow, modifiers: co.union(.shift))
        case .center: return Shortcut(keyCode: kVK_ANSI_C, key: "c", modifiers: co)
        case .larger: return Shortcut(keyCode: kVK_ANSI_Equal, key: "=", modifiers: co)
        case .smaller: return Shortcut(keyCode: kVK_ANSI_Minus, key: "-", modifiers: co)
        case .restore: return Shortcut(keyCode: kVK_Delete, key: .delete, modifiers: co)
        case .previousDisplay: return Shortcut(keyCode: kVK_LeftArrow, key: .leftArrow, modifiers: co.union(.command))
        case .nextDisplay: return Shortcut(keyCode: kVK_RightArrow, key: .rightArrow, modifiers: co.union(.command))
        }
    }
}

/// システム全体で効くショートカット。
///
/// Carbon の `RegisterEventHotKey` を使う。古い API だが、「他のアプリが手前にあっても
/// 効くショートカット」を作る方法は今もこれが正規で、Rectangle も（MASShortcut 経由で）
/// これを使っている。
///
/// ⌘ の単独押しを見ている `NSEvent.addGlobalMonitorForEvents` とは性質が違う:
///
/// - 覗くのではなく**受け取る**。登録したキーは手前のアプリに届かない。⌃⌥← で
///   ウィンドウを動かしたら、テキスト欄のカーソルまで一緒に動いた、ということが起きない。
/// - アクセシビリティの許可が要らない。ただし、ウィンドウを動かすほうには要る。
///
/// 分かっていること: **合成したキー入力（`CGEvent.post`）では発火しない。**
/// 試験のために ⌃⌥← などを合成して送っても、試験用に作った受け手も Rectangle も
/// 反応しなかった（2026-09-23）。
/// ショートカットの確認だけは、実際のキーボードで押すしかない。
final class HotKeys {
    /// 登録したショートカットが押されたときに呼ばれる。
    var onPress: ((WindowAction) -> Void)?

    /// 登録したものの ID から操作を引く表。ID は配列の添字 + 1（0 は使わない）。
    private var actions: [WindowAction] = []
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// One が登録したショートカットだと分かるように付ける印。4文字を1つの数に詰めたもの（'One '）。
    private static let signature: OSType = 0x4F6E_6520

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    /// 操作ごとの既定のショートカットを登録する。前に登録していた分は外してから。
    func register(_ actions: [WindowAction]) {
        unregisterAll()
        installHandler()
        self.actions = actions

        var failed: [String] = []
        for (index, action) in actions.enumerated() {
            let shortcut = action.shortcut
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append("\(action.title)(\(status))")
            }
        }

        // 他のアプリが同じキーを使っていても、登録そのものは成功する（Rectangle が動いて
        // いる横で試して確かめた）。なので「失敗=0」は「このキーを One だけが使っている」
        // という意味ではない。
        log.notice("ウィンドウのショートカットを登録した 成功=\(self.refs.count, privacy: .public) 失敗=\(failed.count, privacy: .public)")
        if !failed.isEmpty {
            log.error("登録できなかったショートカット: \(failed.joined(separator: " "), privacy: .public)")
        }
    }

    /// 登録したショートカットを全部外す。
    func unregisterAll() {
        guard !refs.isEmpty else { return }
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        actions = []
        log.notice("ウィンドウのショートカットを外した")
    }

    /// 押されたことを受け取る窓口を、アプリに1つだけ置く。
    ///
    /// Carbon のイベントは C の関数ポインタで受け取る。C の関数ポインタには、周りの
    /// 変数を掴んだクロージャを渡せない（掴んだものを置いておく場所が無い）。
    /// なので self は `userData`（C の `void *`）として別に渡し、呼ばれたときに取り出す。
    ///
    /// `passUnretained` は「参照カウントを増やさずにポインタにする」。self の寿命は
    /// 持ち主（`AppModel`）が保証していて、self が消えるときには `deinit` で窓口ごと
    /// 外すので、ここで self を掴み続ける必要は無い。
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr else { return status }
            Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().pressed(id)
            return noErr
        }, 1, &spec, me, &handler)
        if status != noErr {
            log.error("ショートカットの受け口を置けない status=\(status, privacy: .public)")
        }
    }

    private func pressed(_ id: EventHotKeyID) {
        let index = Int(id.id) - 1
        guard id.signature == Self.signature, actions.indices.contains(index) else { return }
        onPress?(actions[index])
    }
}
