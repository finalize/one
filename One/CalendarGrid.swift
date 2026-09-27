import Foundation

/// 月の表に並べる日と、予定をどの日に出すかの計算。
///
/// 画面にもカレンダー.app にも触らない。暦（`Calendar`）と日付だけを受け取るので、
/// 週の始まりが日曜の暦でも月曜の暦でも、どの月でもテストで確かめられる。
enum CalendarGrid {
    /// 表の週の数。
    ///
    /// 月によって 4〜6 週にまたがるが、表の高さを月ごとに変えると、月を送るたびに窓の
    /// 高さが変わり、前後の月へ送るボタンの位置もずれて続けて押せない。いつも 6 週にして、
    /// 前後の月の日で埋める。
    static let weeks = 6

    /// `month` を含む月の表に並べる日。週の始まりの日から `weeks` 週ぶん、その日の 0:00。
    ///
    /// 1日がその週の何日目かは `calendar.firstWeekday`（日曜なら 1、月曜なら 2）で決まる。
    static func days(for month: Date, calendar: Calendar) -> [Date] {
        let firstOfMonth = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth) else { return [] }
        // 足し算は暦に任せる。24 時間を足すと、夏時間の切り替わる日に 23:00 や 1:00 になる。
        return (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// 曜日の見出し。週の始まりの曜日から順に（日本語の暦なら「日 月 火 …」）。
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = (calendar.firstWeekday - 1) % symbols.count
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// その予定を `day`（その日の 0:00）の欄に出すか。
    ///
    /// 予定の終わりは、その瞬間を含まない。終日の予定は翌日の 0:00 に終わる形で届くので、
    /// 含めると翌日にも出てしまう。長さが 0 の予定（締め切りなど）は、始まる日にだけ出す。
    static func overlaps(start: Date, end: Date, day: Date, calendar: Calendar) -> Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        if end <= start {
            return day <= start && start < next
        }
        return start < next && day < end
    }

    /// 一覧に出す時刻の表記。`day` の中で始まり・終わるならその時刻、日をまたぐ側は空ける。
    ///
    /// 10:00–11:00 / 22:00–（翌日まで続く）/ –9:00（前の日から続く）/ 終日
    static func timeLabel(start: Date, end: Date, isAllDay: Bool, day: Date, calendar: Calendar) -> String {
        if isAllDay { return "終日" }
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return "" }
        let from = start >= day ? clock(start, calendar: calendar) : ""
        let to = end <= next ? clock(end, calendar: calendar) : ""
        if end <= start { return from }
        return "\(from)–\(to)"
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
