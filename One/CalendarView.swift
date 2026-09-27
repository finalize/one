import SwiftUI

/// カレンダーの小窓の中身。上に月の表、下に選んだ日の予定。
///
/// 大きさはいつも同じにしてある。表はいつも 6 週（`CalendarGrid.weeks`）、予定の欄は
/// 高さを決めて中でスクロールさせる。中身に合わせて窓が伸び縮みすると、月を送るボタンの
/// 位置がずれて続けて押せないし、アイコンの下に置き直す手間も増える。
struct CalendarView: View {
    let model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            MonthGrid(model: model)
            Divider()
            DayEvents(model: model)
            HStack {
                Spacer()
                Button("カレンダーを開く") { model.openCalendarApp() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // 暦と言語に合わせた書き方になる（日本語なら「2026年9月」）。
            Text(model.month.formatted(.dateTime.year().month(.wide)))
                .font(.headline)
            Spacer()
            Button { model.showPreviousMonth() } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 20)
            }
            .help("前の月")
            Button("今日") { model.showToday() }
            Button { model.showNextMonth() } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 20)
            }
            .help("次の月")
        }
        .buttonStyle(.borderless)
    }
}

private struct MonthGrid: View {
    let model: CalendarModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            // 曜日の見出しは同じ字が2回出る暦もある（英語の T と S）ので、位置で見分ける。
            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 16)
            }
            ForEach(model.days, id: \.self) { day in
                DayCell(
                    number: model.calendar.component(.day, from: day),
                    isToday: day == model.today,
                    isSelected: day == model.selectedDay,
                    isInMonth: model.isInShownMonth(day),
                    colors: dotColors(on: day)
                ) {
                    model.select(day)
                }
            }
        }
    }

    /// 日の下に出す点の色。予定のカレンダーの色を、重ならないように3つまで。
    private func dotColors(on day: Date) -> [NSColor] {
        var colors: [NSColor] = []
        for event in model.events(on: day) where !colors.contains(event.color) {
            colors.append(event.color)
            if colors.count == 3 { break }
        }
        return colors
    }
}

private struct DayCell: View {
    let number: Int
    let isToday: Bool
    let isSelected: Bool
    let isInMonth: Bool
    let colors: [NSColor]
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 2) {
                Text("\(number)")
                    .font(.system(size: 12, weight: isToday ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(foreground)
                    .frame(width: 26, height: 26)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(Color(nsColor: color)).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            // 余白も押せるように。無いと数字の上しか反応しない。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        if isSelected { return .white }
        if isToday { return .accentColor }
        return isInMonth ? .primary : .secondary.opacity(0.6)
    }
}

private struct DayEvents: View {
    let model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selectedDay.formatted(.dateTime.month().day().weekday(.abbreviated)))
                .font(.subheadline.weight(.semibold))
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 150, alignment: .top)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.access {
        case .notAsked:
            Text("カレンダーを読む許可を待っています…")
                .foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("カレンダーを読む許可がありません。")
                    .foregroundStyle(.secondary)
                Button("システム設定を開く…") { model.openPrivacySettings() }
            }
        case .granted:
            let events = model.events(on: model.selectedDay)
            if events.isEmpty {
                Text("予定はありません")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(events) { event in
                            EventRow(event: event, day: model.selectedDay, calendar: model.calendar) {
                                model.open(event)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarModel.Event
    let day: Date
    let calendar: Calendar
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: event.color))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title.isEmpty ? "（題なし）" : event.title)
                        .lineLimit(1)
                    Text(CalendarGrid.timeLabel(
                        start: event.start, end: event.end, isAllDay: event.isAllDay, day: day, calendar: calendar
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("カレンダーで開く")
    }
}
