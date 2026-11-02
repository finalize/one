import SwiftUI

struct TrackpadSettings: View {
    @Bindable var trackpad: TrackpadModel

    var body: some View {
        Form {
            Toggle(isOn: $trackpad.adjustsWithEdges) {
                Text("端をなぞって音量とキーボードの明るさを変える")
                Text("トラックパッドの右の端を指1本で上下になぞると音量が、左の端だとキーボードの明るさが変わる。キーで変えたときと同じ表示が出る。キーボードの明るさが変わるのは、バックライトのあるキーボード（MacBook の内蔵キーボード）だけ。")
            }
        }
    }
}
