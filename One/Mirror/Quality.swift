/// 画質の選択肢。
///
/// macOS ではセッションのプリセットから選ぶ。iOS には `activeFormat` を直接決めて
/// セッションを「入力優先」（`AVCaptureSessionPresetInputPriority`）に切り替える道が
/// あるが、この定数は macOS では使えない（SDK のヘッダで `API_UNAVAILABLE(macos)`）。
/// なので決まった段から選ぶ形にしている。
///
/// AVFoundation を import しない。プリセットとの対応は `Camera.swift` に置き、ここは
/// 選択肢の並びと、保存した値をどう読み戻すかだけを持つ（カメラ無しでテストするため）。
enum Quality: String, CaseIterable {
    case auto
    case uhd2160 = "2160"
    case fhd1080 = "1080"
    case hd720 = "720"
    case qhd540 = "540"
    case vga480 = "480"

    var label: String {
        switch self {
        case .auto: "自動"
        case .uhd2160: "4K（3840×2160）"
        case .fhd1080: "1080p（1920×1080）"
        case .hd720: "720p（1280×720）"
        case .qhd540: "540p（960×540）"
        case .vga480: "480p（640×480）"
        }
    }

    /// 保存してある値を読み戻す。知らない値（消した段など）なら自動。
    init(saved: String?) {
        self = saved.flatMap(Quality.init(rawValue:)) ?? .auto
    }

    /// 選んだ段が今のカメラで使えなければ、自動に落とす。
    ///
    /// 保存してある値は書き換えない。4K のカメラで 4K を選び、内蔵カメラに切り替え、
    /// また 4K のカメラに戻したときに、4K に戻ってほしいからだ。
    func effective(supported: (Quality) -> Bool) -> Quality {
        self == .auto || supported(self) ? self : .auto
    }
}
