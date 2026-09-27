import SwiftUI

/// 設定の窓の各タブの中身。窓とタブそのものは `SettingsWindow` が AppKit で組む。
///
/// 前は SwiftUI の `Settings` シーンの中に `TabView` を置いていた。アイコンの左右の
/// クリックを見分けるためにメニューバーの部分を AppKit にしたところ、`Settings` シーンを
/// 開く手段が無くなった。開く `openSettings` は SwiftUI の画面の中からしか呼べず、
/// AppKit のメニューからは届かない。中身は SwiftUI のまま、入れ物だけを AppKit にしてある。
///
/// `@Bindable` は `@Observable` なオブジェクトから `$model.isSwapped` の形で
/// 双方向の結び付き（Binding）を作れるようにする印。Toggle のように
/// 「読むだけでなく書き換えもする」部品に渡すときに必要になる。
extension View {
    /// 設定の1ページの形にそろえる。
    ///
    /// `.grouped` は、システム設定と同じ「角の丸い箱に項目を並べる」見た目。幅は固定し、
    /// 高さは中身に任せる。窓はこの大きさに合わせて、タブを切り替えるたびに伸び縮みする。
    func settingsPage() -> some View {
        formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("ログイン時に起動", isOn: $model.launchesAtLogin)

            Section("許可") {
                // `LabeledContent` は「左に名前、右に値」の1行。
                LabeledContent("アクセシビリティ") {
                    if model.isTrusted {
                        Text("あり")
                    } else {
                        Button("システム設定を開く…") { model.openAccessibilitySettings() }
                    }
                }
                Text("⌘ の単独押しを見るのと、ほかのアプリのウィンドウを動かすのに使う。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InputSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("左 ⌘", value: model.isSwapped ? model.kanaName : model.asciiName)
                LabeledContent("右 ⌘", value: model.isSwapped ? model.asciiName : model.kanaName)
                Toggle("左右を入れ替える", isOn: $model.isSwapped)
            } footer: {
                Text("⌘ を押して、ほかのキーもクリックも挟まずに離すと切り替わる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Toggle の見出しに Text を2つ書くと、2つ目は説明として小さく出る。
            Toggle(isOn: $model.showsMode) {
                Text("メニューバーに A / あ も出す")
                Text("macOS の入力メニューが同じものを出しているなら、二重になるだけなので要らない。")
            }
        }
    }
}

struct WindowSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle(isOn: $model.arrangesWindows) {
                Text("ショートカットで動かす")
                Text("⌃⌥← などで、手前のウィンドウを半分や 1/3 に並べる。キーは右クリックのメニューの「ウィンドウ」に出る。Rectangle と一緒に使うなら切る。メニューから選んで動かすのは、切っていてもできる。")
            }
            Toggle(isOn: $model.snapsWindows) {
                Text("ドラッグで端に寄せて並べる")
                Text("macOS 自身の、端へ寄せて並べる機能（システム設定 > デスクトップと Dock）を使うなら切る。両方入っていると1回のドラッグに両方が反応する。")
            }
        }
    }
}

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
