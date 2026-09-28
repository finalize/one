import SwiftUI

struct CalendarSettings: View {
    @Bindable var model: AppModel
    let calendar: CalendarModel

    var body: some View {
        Form {
            Section("メニューバーの ⌘") {
                Picker("左クリック", selection: $model.leftClickShowsCalendar) {
                    Text("カレンダー（右クリックでメニュー）").tag(true)
                    Text("メニュー（右クリックでカレンダー）").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            if calendar.access == .granted {
                Section {
                    Picker("祝日のカレンダー", selection: holidayCalendar) {
                        // nil を「なし」に当てる。タグの型は選んだものと同じ `String?` に揃える。
                        Text("なし").tag(String?.none)
                        ForEach(calendar.calendars) { item in
                            Text(item.title).tag(Optional(item.id))
                        }
                    }
                } footer: {
                    Text("このカレンダーに終日の予定がある日を、日曜と同じ赤にする。下で隠していても赤くなる。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // アカウントごとに箱を分ける。並びは `CalendarModel.calendars` のまま（アカウント、名前の順）。
                ForEach(accounts, id: \.self) { account in
                    Section(account) {
                        ForEach(calendar.calendars.filter { $0.account == account }) { item in
                            Toggle(isOn: shown(item.id)) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(nsColor: item.color)).frame(width: 10, height: 10)
                                    Text(item.title)
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("カレンダーを読む許可が無いので、カレンダーを選べない。「一般」タブの「許可」から与える。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// アカウントの名前。並び順を保ったまま、重ねずに。
    private var accounts: [String] {
        var seen: [String] = []
        for item in calendar.calendars where !seen.contains(item.account) {
            seen.append(item.account)
        }
        return seen
    }

    /// 出すかどうかのスイッチ。値は `CalendarModel` が「隠すもの」として持っているので、
    /// 読み書きの手続きを自分で書いて Binding を作る。
    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { calendar.isShown(id) }, set: { calendar.setShown(id, $0) })
    }

    private var holidayCalendar: Binding<String?> {
        Binding(get: { calendar.holidayCalendarID }, set: { calendar.setHolidayCalendar($0) })
    }
}
