import AppKit
import IOKit.hidsystem

/// 音量・画面の明るさ・キーボードの明るさのキー。押したことにして、macOS に変えさせる。
///
/// 音量や明るさを自分で書き換えず、キーを送る。こうすると、キーで変えたときと同じ表示が出て、
/// 1回で動く量（16 段）も、どの出力先・どの画面に効くかも macOS のままになる。英数 / かなを
/// キーで送っている（`InputSource.pressJISKey`）のと同じ考え。
///
/// 明るさのキーが効くのは、macOS が明るさを変えられる画面（内蔵の画面と Apple のディスプレイ）だけ。
/// ほかのメーカーのディスプレイは DDC という別の道でしか変えられず、それには Apple が公開していない
/// 仕組みが要るので、やらない。
///
/// キーボードの明るさのキーが効くのは、バックライトのあるキーボード（MacBook の内蔵キーボード）だけ。
/// Magic Keyboard にはバックライトが無い。
enum MediaKey {
    case volumeUp
    case volumeDown
    case brightnessUp
    case brightnessDown
    case keyboardBrightnessUp
    case keyboardBrightnessDown

    /// IOKit の `NX_KEYTYPE_…`。音量・明るさのキーは、文字のキーと違ってキーコードを持たず、
    /// この番号を載せた「システム定義」のイベントとして届く。
    private var keyType: Int32 {
        switch self {
        case .volumeUp: NX_KEYTYPE_SOUND_UP
        case .volumeDown: NX_KEYTYPE_SOUND_DOWN
        case .brightnessUp: NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: NX_KEYTYPE_BRIGHTNESS_DOWN
        case .keyboardBrightnessUp: NX_KEYTYPE_ILLUMINATION_UP
        case .keyboardBrightnessDown: NX_KEYTYPE_ILLUMINATION_DOWN
        }
    }

    /// 押して離したことにする。イベントを作れたら true。
    ///
    /// イベントを送るにはアクセシビリティの許可が要るが、⌘ を見張るのに既に持っている。
    @discardableResult
    func press() -> Bool {
        // 押す（0xA）と離す（0xB）の2つを送る。data1 の上の 16 ビットがキーの番号、
        // その下の 8 ビットが押す / 離す。修飾キーの欄にも同じ押す / 離すを入れるのが決まり。
        // 修飾キーは載せない。⌥ を載せるとサウンドの設定が開き、⇧⌥ だと 1/4 段になる。
        for state: Int32 in [0xA, 0xB] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: Int((keyType << 16) | (state << 8)),
                data2: -1
            ), let cgEvent = event.cgEvent else { return false }
            cgEvent.post(tap: .cghidEventTap)
        }
        return true
    }
}
