import SwiftUI

struct InputSettings: View {
    @Bindable var input: InputModel

    var body: some View {
        Form {
            Section {
                LabeledContent("左 ⌘", value: input.isSwapped ? input.kanaName : input.asciiName)
                LabeledContent("右 ⌘", value: input.isSwapped ? input.asciiName : input.kanaName)
                Toggle("左右を入れ替える", isOn: $input.isSwapped)
            } footer: {
                Text("⌘ を押して、ほかのキーもクリックも挟まずに離すと切り替わる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Toggle の見出しに Text を2つ書くと、2つ目は説明として小さく出る。
            Toggle(isOn: $input.showsMode) {
                Text("メニューバーに A / あ も出す")
                Text("macOS の入力メニューが同じものを出しているなら、二重になるだけなので要らない。")
            }
        }
    }
}
