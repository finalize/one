import SwiftUI

struct MirrorSettings: View {
    @Bindable var mirror: MirrorModel

    var body: some View {
        Form {
            Section {
                Picker("カメラ", selection: $mirror.cameraID) {
                    // nil を「自動」に当てる。タグの型は `cameraID` と同じ `String?` に揃える。
                    Text("自動").tag(String?.none)
                    ForEach(mirror.cameras, id: \.id) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                Picker("画質", selection: $mirror.quality) {
                    // 今のカメラで使えない段は並べない。Picker の項目には `.disabled` が効かず
                    // （ポップアップでもラジオボタンでも、灰色にならずに選べてしまう）、
                    // 並べないことで代える。
                    //
                    // ただし選んである段は、使えなくても出す。無いと Picker が今の選択を見失う。
                    // 4K のカメラで 4K を選んだまま内蔵カメラに切り替えたときがこれ。
                    ForEach(qualities, id: \.self) { quality in
                        Text(mirror.supports(quality) ? quality.label : "\(quality.label)（このカメラでは使えない）")
                            .tag(quality)
                    }
                }
                if let resolution = mirror.activeResolution {
                    LabeledContent("いま映っている", value: resolution)
                }
            } footer: {
                Text("今のカメラで使えない画質は出さない。選んであった画質が使えないカメラでは、自動で映す。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("鏡像にする", isOn: $mirror.isMirrored)
                Toggle("外をクリックしても閉じない", isOn: $mirror.isPinned)
                Toggle(isOn: $mirror.opensFromNotch) {
                    Text("ノッチのクリックで開く")
                    Text("ノッチの無い Mac では、アイコンの右クリックのメニューの「鏡を出す」で開く。")
                }
            }

            // この窓は One の窓なので、ここを押しても鏡は閉じない（外のクリックにならない）。
            // 鏡を出したまま上の設定を変えると、映りがその場で変わる。
            Button(mirror.isVisible ? "鏡を隠す" : "鏡を出して確かめる") { mirror.toggleUnderMouse() }
        }
    }

    /// 画質の選択肢。今のカメラで使える段と、選んである段。
    private var qualities: [Quality] {
        Quality.allCases.filter { mirror.supports($0) || $0 == mirror.quality }
    }
}
