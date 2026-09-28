import SwiftUI

struct GeneralSettings: View {
    @Bindable var model: AppModel
    let calendar: CalendarModel

    var body: some View {
        Form {
            Toggle("ログイン時に起動", isOn: $model.launchesAtLogin)

            Section("許可") {
                // `LabeledContent` は「左に名前、右に値」の1行。名前に Text を2つ書くと、
                // 2つ目は説明として小さく出る（Toggle と同じ）。
                LabeledContent {
                    if model.isTrusted {
                        Text("あり")
                    } else {
                        Button("システム設定を開く…") { model.openAccessibilitySettings() }
                    }
                } label: {
                    Text("アクセシビリティ")
                    Text("⌘ の単独押しを見るのと、ほかのアプリのウィンドウを動かすのに使う。")
                }
                LabeledContent {
                    switch calendar.access {
                    case .granted: Text("あり")
                    case .notAsked: Button("許可を求める") { calendar.requestAccess() }
                    case .denied: Button("システム設定を開く…") { calendar.openPrivacySettings() }
                    }
                } label: {
                    Text("カレンダー")
                    Text("予定を月の表に並べるのに使う。読むだけで、書き換えない。")
                }
            }
        }
    }
}
