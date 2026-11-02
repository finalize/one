import SwiftUI

struct TrackpadSettings: View {
    @Bindable var trackpad: TrackpadModel

    var body: some View {
        Form {
            Toggle(isOn: $trackpad.adjustsWithEdges) {
                Text("左右の端をなぞって音量と明るさを変える")
                Text("トラックパッドの右の端を指1本で上下になぞると音量が、左の端だと画面の明るさが変わる。キーで変えたときと同じ表示が出る。画面の明るさが変わるのは、内蔵の画面と Apple のディスプレイだけ。")
            }
            Toggle(isOn: $trackpad.adjustsKeyboardWithTopEdge) {
                Text("上の端をなぞってキーボードの明るさを変える")
                Text("トラックパッドの上の端を指1本で右へなぞると明るく、左へなぞると暗くなる。バックライトのあるキーボード（MacBook の内蔵キーボード）だけ。")
            }
        }
    }
}
