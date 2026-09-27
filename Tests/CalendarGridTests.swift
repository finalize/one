import Foundation

// カレンダーの月の表と、予定をどの日の欄に出すか（CalendarGrid）を確かめる。
//
// 実装を見ずに、下の決めごとだけから書いた。今の実装の写しではなく、仕様を固定するためのテスト。
// 落ちたら期待値ではなく実装を疑う。
//
// この Mac の地域・時間帯・週の始まりに左右されないよう、暦はいつもグレゴリオ暦に
// 時間帯・地域・週の始まりを明示して作る。日付も暦と DateComponents から作り、現在時刻は使わない。
//
// 決めごと（テスト名の先頭の [n] がこの番号）
//  1. 月の表はいつも 6 週（42 日）。前後の月の日で埋める。
//  2. month は、その月の中のどの瞬間でもよい。
//  3. 返す日はどれも暦の時間帯でのその日の 0:00。1 日ずつ連続する。
//  4. 先頭は、1日を含む週の、週の始まり（firstWeekday）の日。1日が週の始まりなら 1日が先頭。
//  5. 夏時間の切り替わる月でも、どの日も 0:00（24 時間ずつ足した値ではない）。
//  6. weekdaySymbols は veryShortStandaloneWeekdaySymbols を週の始まりから並べた 7 つ。
//  7. overlaps は予定 [start, end) がその日 [day, 翌日 0:00) に重なるか。終わりの瞬間は含まない。
//  8. 長さ 0 の予定（end <= start）は start を含む日にだけ出す。
//  9. 何日もまたがる予定は、またいだどの日にも出る。
// 10. timeLabel の書き方。

private var failures = 0

private func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name)  期待=\(expected) 実際=\(actual)")
}

/// 多くの場合を一度に見る性質のテスト。破れた場合の数を 0 と比べ、破れた例を最初のいくつか出す。
private func checkEvery(_ name: String, cases: Int, _ violations: [String]) {
    check("\(name)（\(cases) 通り）", violations.count, 0)
    for v in violations.prefix(5) { print("        例: \(v)") }
}

private let tokyo = "Asia/Tokyo"
private let newYork = "America/New_York"  // 夏時間がある

/// この Mac の設定に依らない暦。時間帯・地域・週の始まりを全部決める。
private func makeCalendar(_ zone: String, firstWeekday: Int = 1, locale: String = "ja_JP") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    c.locale = Locale(identifier: locale)
    c.firstWeekday = firstWeekday
    return c
}

/// 暦の時間帯での、その年月日・時刻の瞬間。
private func at(_ c: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// 暦の時間帯での日付だけ（「2026-02-01」）。
private func ymd(_ c: Calendar, _ d: Date) -> String {
    let x = c.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", x.year!, x.month!, x.day!)
}

/// 暦の時間帯での日付と時刻（「2026-02-01 00:00:00」）。
private func stamp(_ c: Calendar, _ d: Date) -> String {
    let x = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    return String(format: "%04d-%02d-%02d %02d:%02d:%02d", x.year!, x.month!, x.day!, x.hour!, x.minute!, x.second!)
}

/// その日の 0:00 ちょうどか。同じ年月日から暦で作った 0:00 と、秒以下まで一致すること。
private func isMidnight(_ c: Calendar, _ d: Date) -> Bool {
    c.date(from: c.dateComponents([.year, .month, .day], from: d)) == d
}

/// 表を「年/月/日」の 1 行にする（「2026/7/26 2026/7/27 …」）。結果を読みやすく出すため。
private func line(_ c: Calendar, _ days: [Date]) -> String {
    days.map {
        let x = c.dateComponents([.year, .month, .day], from: $0)
        return "\(x.year!)/\(x.month!)/\(x.day!)"
    }.joined(separator: " ")
}

/// 連続した日付（「2026/2/1」…）。期待する表を日付の並びで書くため。
private func dayRun(_ y: Int, _ m: Int, _ days: ClosedRange<Int>) -> [String] {
    days.map { "\(y)/\(m)/\($0)" }
}

/// 表が短くても落ちずに比べられるよう、範囲外なら nil。
private func item(_ a: [Date], _ i: Int) -> Date? {
    a.indices.contains(i) ? a[i] : nil
}

/// 予定 [start, end) を、並べた日のどれに出すかを「●」（出す）「・」（出さない）で並べる。
private func spread(_ start: Date, _ end: Date, over days: [Date], _ c: Calendar) -> String {
    days.map { CalendarGrid.overlaps(start: start, end: end, day: $0, calendar: c) ? "●" : "・" }.joined()
}

@main
struct CalendarGridTests {
    static func main() {
        // en dash「–」（U+2013）。見た目がハイフン（U+002D）と紛れるので、コードで書く。
        let dash = "\u{2013}"

        let tkSun = makeCalendar(tokyo, firstWeekday: 1)
        let tkMon = makeCalendar(tokyo, firstWeekday: 2)
        let tkSat = makeCalendar(tokyo, firstWeekday: 7)
        let nySun = makeCalendar(newYork, firstWeekday: 1)

        func grid(_ c: Calendar, _ y: Int, _ m: Int) -> [Date] {
            CalendarGrid.days(for: at(c, y, m, 1), calendar: c)
        }

        // MARK: 1. 月の表はいつも 6 週（42 日）

        check("[1] 表は 6 週", CalendarGrid.weeks, 6)

        // ここが設計の判断: 月によって 4〜6 週にまたがるが、月を送るたびに表の高さが変わらないよう、
        // いつも 42 日を返して前後の月の日で埋める。
        // 2026年2月は 1日が日曜で 28 日しかなく、日曜始まりならちょうど 4 週に収まる。それでも 42 日。
        check(
            "[1] 4 週に収まる月（2026年2月・日曜始まり）でも 42 日、後ろの 2 週は翌月の日で埋める",
            line(tkSun, grid(tkSun, 2026, 2)),
            (dayRun(2026, 2, 1...28) + dayRun(2026, 3, 1...14)).joined(separator: " ")
        )
        check(
            "[1] 5 週にまたがる月（2026年9月・日曜始まり）でも 42 日、前後を埋める",
            line(tkSun, grid(tkSun, 2026, 9)),
            (dayRun(2026, 8, 30...31) + dayRun(2026, 9, 1...30) + dayRun(2026, 10, 1...10)).joined(separator: " ")
        )
        check(
            "[1] 6 週にまたがる月（2026年8月・日曜始まり）",
            line(tkSun, grid(tkSun, 2026, 8)),
            (dayRun(2026, 7, 26...31) + dayRun(2026, 8, 1...31) + dayRun(2026, 9, 1...5)).joined(separator: " ")
        )
        check(
            "[1] 閏年の 2 月（2024年2月・日曜始まり）は 29日まで入れて 42 日",
            line(tkSun, grid(tkSun, 2024, 2)),
            (dayRun(2024, 1, 28...31) + dayRun(2024, 2, 1...29) + dayRun(2024, 3, 1...9)).joined(separator: " ")
        )
        check(
            "[1] 月曜始まり（2026年2月）でも 42 日、1日（日曜）の前の月曜から",
            line(tkMon, grid(tkMon, 2026, 2)),
            (dayRun(2026, 1, 26...31) + dayRun(2026, 2, 1...28) + dayRun(2026, 3, 1...8)).joined(separator: " ")
        )

        // MARK: 2. month は、その月の中のどの瞬間でもよい

        let august = grid(tkSun, 2026, 8)
        check(
            "[2] 月の途中の瞬間（8月15日 12:34:56）を渡しても、1日 0:00 を渡したのと同じ表",
            line(tkSun, CalendarGrid.days(for: at(tkSun, 2026, 8, 15, 12, 34, 56), calendar: tkSun)),
            line(tkSun, august)
        )
        check(
            "[2] 月末の 23:59:59（8月31日）を渡しても、1日 0:00 を渡したのと同じ表",
            line(tkSun, CalendarGrid.days(for: at(tkSun, 2026, 8, 31, 23, 59, 59), calendar: tkSun)),
            line(tkSun, august)
        )

        // どの月の中かは、渡した暦の時間帯で決まる。東京の 9月1日 0:30 は、ニューヨークではまだ 8月31日 11:30。
        let sep1Tokyo = at(tkSun, 2026, 9, 1, 0, 30)
        check(
            "[2] 東京の 9月1日 0:30 を東京の暦で渡すと 9 月の表（8月30日の日曜から）",
            CalendarGrid.days(for: sep1Tokyo, calendar: tkSun).first.map { ymd(tkSun, $0) },
            "2026-08-30"
        )
        check(
            "[2] 同じ瞬間をニューヨークの暦で渡すと 8 月の表（7月26日の日曜から）",
            CalendarGrid.days(for: sep1Tokyo, calendar: nySun).first.map { ymd(nySun, $0) },
            "2026-07-26"
        )

        // MARK: 3. どれも暦の時間帯でのその日の 0:00、1 日ずつ連続

        check(
            "[3] 先頭は東京の 7月26日 0:00 そのもの（2026年8月・日曜始まり）",
            august.first,
            at(tkSun, 2026, 7, 26)
        )
        check(
            "[3] 月の途中の瞬間から作っても、どの日も 0:00（0:00 でない日の一覧が空）",
            CalendarGrid.days(for: at(tkSun, 2026, 8, 15, 12, 34, 56), calendar: tkSun)
                .filter { !isMidnight(tkSun, $0) }.map { stamp(tkSun, $0) },
            []
        )
        check(
            "[3] ニューヨークの暦ではニューヨークの 0:00（先頭は 2026年7月26日 0:00 EDT）",
            grid(nySun, 2026, 8).first,
            at(nySun, 2026, 7, 26)
        )

        // MARK: 4. 先頭は、1日を含む週の、週の始まりの日

        check(
            "[4] 1日が週の始まり（日曜）なら 1日が先頭で、前の月の日は入らない（2026年3月・日曜始まり）",
            grid(tkSun, 2026, 3).first.map { ymd(tkSun, $0) },
            "2026-03-01"
        )
        check(
            "[4] 1日が週の始まり（月曜）なら 1日が先頭（2026年6月・月曜始まり）",
            grid(tkMon, 2026, 6).first.map { ymd(tkMon, $0) },
            "2026-06-01"
        )
        check(
            "[4] 同じ 2026年6月でも日曜始まりなら、前の日曜（5月31日）から",
            grid(tkSun, 2026, 6).first.map { ymd(tkSun, $0) },
            "2026-05-31"
        )
        check(
            "[4] 土曜始まり（firstWeekday = 7）なら、1日（火曜）の前の土曜から（2026年9月）",
            grid(tkSat, 2026, 9).first.map { ymd(tkSat, $0) },
            "2026-08-29"
        )

        // MARK: 5. 夏時間の切り替わる月でも、どの日も 0:00

        // ニューヨークでは 2026年3月8日 2:00 に時計が 3:00 に進む。この日は 23 時間しかない。
        let march = grid(nySun, 2026, 3)
        check(
            "[5] 夏時間の始まる月（ニューヨーク 2026年3月）でも、どの日も 0:00（0:00 でない日の一覧が空）",
            march.filter { !isMidnight(nySun, $0) }.map { stamp(nySun, $0) },
            []
        )
        check(
            "[5] 夏時間の始まる日（3月8日）の次の欄は 3月9日 0:00（23 時間後。24 時間足した 1:00 ではない）",
            item(march, 8),
            at(nySun, 2026, 3, 9)
        )

        // ニューヨークでは 2026年11月1日 2:00 に時計が 1:00 に戻る。この日は 25 時間ある。
        let november = grid(nySun, 2026, 11)
        check(
            "[5] 夏時間の終わる月（ニューヨーク 2026年11月）でも、どの日も 0:00（0:00 でない日の一覧が空）",
            november.filter { !isMidnight(nySun, $0) }.map { stamp(nySun, $0) },
            []
        )
        check(
            "[5] 夏時間の終わる日（11月1日）の次の欄は 11月2日 0:00（25 時間後。24 時間足した 11月1日 23:00 ではない）",
            item(november, 1),
            at(nySun, 2026, 11, 2)
        )

        // MARK: 6. 曜日の見出し

        check(
            "[6] 日本語・日曜始まりの見出しは「日 月 火 水 木 金 土」",
            CalendarGrid.weekdaySymbols(calendar: tkSun),
            ["日", "月", "火", "水", "木", "金", "土"]
        )
        check(
            "[6] 日本語・月曜始まりの見出しは「月 火 水 木 金 土 日」",
            CalendarGrid.weekdaySymbols(calendar: tkMon),
            ["月", "火", "水", "木", "金", "土", "日"]
        )
        check(
            "[6] 日本語・土曜始まりの見出しは「土 日 月 火 水 木 金」",
            CalendarGrid.weekdaySymbols(calendar: tkSat),
            ["土", "日", "月", "火", "水", "木", "金"]
        )
        check(
            "[6] 見出しは渡した暦の地域の記号（英語の暦・月曜始まりなら M T W T F S S）",
            CalendarGrid.weekdaySymbols(calendar: makeCalendar(tokyo, firstWeekday: 2, locale: "en_US")),
            ["M", "T", "W", "T", "F", "S", "S"]
        )

        // MARK: 7〜9. 予定をどの日の欄に出すか

        // 東京の 2026年9月26日〜30日の 5 日を並べ、予定が出る日を ● で表す。
        // 「・・●・・」なら 28日（月）だけに出る。
        let tk = tkSun
        let fiveDays = (26...30).map { at(tk, 2026, 9, $0) }
        func shownOn(_ start: Date, _ end: Date) -> String { spread(start, end, over: fiveDays, tk) }

        check(
            "[7] その日の中の予定（28日 10:00–11:00）はその日だけに出る",
            shownOn(at(tk, 2026, 9, 28, 10), at(tk, 2026, 9, 28, 11)),
            "・・●・・"
        )
        // ここが設計の判断: 終わりはその瞬間を含まない。翌日の 0:00 に終わる予定は翌日に出ない。
        check(
            "[7] 翌日 0:00 ちょうどに終わる予定（28日 23:00–29日 0:00）は翌日に出ない",
            shownOn(at(tk, 2026, 9, 28, 23), at(tk, 2026, 9, 29)),
            "・・●・・"
        )
        check(
            "[7] 翌日 0:00 の 1 秒後に終わる予定（28日 23:00–29日 0:00:01）は翌日にも出る",
            shownOn(at(tk, 2026, 9, 28, 23), at(tk, 2026, 9, 29, 0, 0, 1)),
            "・・●●・"
        )
        check(
            "[7] その日の 0:00 ちょうどに始まる予定（29日 0:00–1:00）はその日に出て、前の日には出ない",
            shownOn(at(tk, 2026, 9, 29), at(tk, 2026, 9, 29, 1)),
            "・・・●・"
        )
        // ここが設計の判断: 終日の予定は 0:00 から翌日 0:00 の形で届くので、その日だけに出る。
        check(
            "[7] 終日の予定（28日 0:00–29日 0:00）はその日だけに出る",
            shownOn(at(tk, 2026, 9, 28), at(tk, 2026, 9, 29)),
            "・・●・・"
        )
        check(
            "[7][9] 3 日間の終日の予定（27日 0:00–30日 0:00）は 27〜29日に出て、30日には出ない",
            shownOn(at(tk, 2026, 9, 27), at(tk, 2026, 9, 30)),
            "・●●●・"
        )

        check(
            "[8] 長さ 0 の予定（28日 12:00）は start を含む日だけに出る",
            shownOn(at(tk, 2026, 9, 28, 12), at(tk, 2026, 9, 28, 12)),
            "・・●・・"
        )
        check(
            "[8] 長さ 0 の予定が 0:00 ちょうど（28日 0:00）ならその日に出て、前の日には出ない",
            shownOn(at(tk, 2026, 9, 28), at(tk, 2026, 9, 28)),
            "・・●・・"
        )
        check(
            "[8] end < start（28日 12:00 に始まり 11:00 に終わる）は長さ 0 と同じく start の日だけ",
            shownOn(at(tk, 2026, 9, 28, 12), at(tk, 2026, 9, 28, 11)),
            "・・●・・"
        )
        check(
            "[8] end < start で end が前の日（28日 0:30 に始まり 27日 23:00 に終わる）でも start の日だけ",
            shownOn(at(tk, 2026, 9, 28, 0, 30), at(tk, 2026, 9, 27, 23)),
            "・・●・・"
        )

        check(
            "[9] 何日もまたがる予定（27日 22:00–29日 9:00）はまたいだどの日にも出る",
            shownOn(at(tk, 2026, 9, 27, 22), at(tk, 2026, 9, 29, 9)),
            "・●●●・"
        )

        // 夏時間の日は 23 時間・25 時間。その日の範囲は「day + 24 時間」ではなく「翌日の 0:00」まで。
        let ny = nySun
        func shownAround(_ y: Int, _ m: Int, _ d: Int, _ start: Date, _ end: Date) -> String {
            let day = at(ny, y, m, d)
            let days = [-1, 0, 1].map { ny.date(byAdding: .day, value: $0, to: day)! }
            return spread(start, end, over: days, ny)
        }
        check(
            "[7] 25 時間ある日（ニューヨーク 11月1日）の 23:30–23:45 はその日に出る（前後の日には出ない）",
            shownAround(2026, 11, 1, at(ny, 2026, 11, 1, 23, 30), at(ny, 2026, 11, 1, 23, 45)),
            "・●・"
        )
        check(
            "[7] 25 時間ある日（ニューヨーク 11月1日）の終日の予定はその日だけに出る",
            shownAround(2026, 11, 1, at(ny, 2026, 11, 1), at(ny, 2026, 11, 2)),
            "・●・"
        )
        check(
            "[7] 23 時間しかない日（ニューヨーク 3月8日）の翌日 0:30–1:00 の予定は 3月8日に出ない",
            shownAround(2026, 3, 8, at(ny, 2026, 3, 9, 0, 30), at(ny, 2026, 3, 9, 1)),
            "・・●"
        )
        check(
            "[7] 23 時間しかない日（ニューヨーク 3月8日）の終日の予定はその日だけに出る",
            shownAround(2026, 3, 8, at(ny, 2026, 3, 8), at(ny, 2026, 3, 9)),
            "・●・"
        )

        // MARK: 10. 時刻の書き方

        // どれも東京の 2026年9月28日の欄に出すときの表記。
        let day28 = at(tk, 2026, 9, 28)
        func label(_ start: Date, _ end: Date, allDay: Bool = false) -> String {
            CalendarGrid.timeLabel(start: start, end: end, isAllDay: allDay, day: day28, calendar: tk)
        }

        check(
            "[10] その日の中の予定は「始まり–終わり」（10:00–11:00）",
            label(at(tk, 2026, 9, 28, 10), at(tk, 2026, 9, 28, 11)),
            "10:00\(dash)11:00"
        )
        check(
            "[10] 区切りは en dash（U+2013）1 文字だけで、ハイフンではない",
            label(at(tk, 2026, 9, 28, 10), at(tk, 2026, 9, 28, 11)).unicodeScalars
                .filter { !("0"..."9").contains($0) && $0 != ":" }
                .map { String(format: "U+%04X", $0.value) },
            ["U+2013"]
        )
        check(
            "[10] 時は先頭に 0 を付けない（9:30–9:45）",
            label(at(tk, 2026, 9, 28, 9, 30), at(tk, 2026, 9, 28, 9, 45)),
            "9:30\(dash)9:45"
        )
        check(
            "[10] 分は 2 桁（9:05–10:07）",
            label(at(tk, 2026, 9, 28, 9, 5), at(tk, 2026, 9, 28, 10, 7)),
            "9:05\(dash)10:07"
        )
        check(
            "[10] 24 時間制（13:00–14:30。午後 1 時ではない）",
            label(at(tk, 2026, 9, 28, 13), at(tk, 2026, 9, 28, 14, 30)),
            "13:00\(dash)14:30"
        )
        check(
            "[10] 0 時は「0:00」、その日の 0:00 ちょうどに始まればその日の中で始まる（0:00–0:45）",
            label(day28, at(tk, 2026, 9, 28, 0, 45)),
            "0:00\(dash)0:45"
        )
        check(
            "[10] 翌日へ続く予定は終わりを空ける（28日 22:00–29日 2:00 → 22:00–）",
            label(at(tk, 2026, 9, 28, 22), at(tk, 2026, 9, 29, 2)),
            "22:00\(dash)"
        )
        check(
            "[10] 前の日から続く予定は始まりを空ける（27日 22:00–28日 9:00 → –9:00）",
            label(at(tk, 2026, 9, 27, 22), at(tk, 2026, 9, 28, 9)),
            "\(dash)9:00"
        )
        check(
            "[10] 前の日から翌日まで続く予定は両方空ける（27日 22:00–29日 9:00 → –）",
            label(at(tk, 2026, 9, 27, 22), at(tk, 2026, 9, 29, 9)),
            dash
        )
        // ここが設計の判断: 翌日の 0:00 ちょうどに終わる予定は、その日の中で終わったとして終わりを書く。
        check(
            "[10] 翌日 0:00 ちょうどに終わる予定は「23:00–0:00」",
            label(at(tk, 2026, 9, 28, 23), at(tk, 2026, 9, 29)),
            "23:00\(dash)0:00"
        )
        check(
            "[10] 前の日から続き翌日 0:00 ちょうどに終わる予定は「–0:00」",
            label(at(tk, 2026, 9, 27, 20), at(tk, 2026, 9, 29)),
            "\(dash)0:00"
        )
        check(
            "[10] 終日でない、その日の 0:00 から翌日 0:00 の予定は「0:00–0:00」",
            label(day28, at(tk, 2026, 9, 29)),
            "0:00\(dash)0:00"
        )
        check(
            "[10] 翌日 0:00 を 1 分過ぎて終わる予定は翌日へ続く（23:00–）",
            label(at(tk, 2026, 9, 28, 23), at(tk, 2026, 9, 29, 0, 1)),
            "23:00\(dash)"
        )
        check(
            "[10] 長さ 0 の予定は始まりだけで、区切りも付けない（9:00）",
            label(at(tk, 2026, 9, 28, 9), at(tk, 2026, 9, 28, 9)),
            "9:00"
        )
        check(
            "[10] 長さ 0 の予定が 0:00 ちょうどなら「0:00」",
            label(day28, day28),
            "0:00"
        )
        // 決めごと 8 は overlaps について「end < start も長さ 0 と同じ扱い」と言うだけで、
        // timeLabel については書いていなかった。長さ 0 と同じく始まりだけ、と決めた（2026-09-28）。
        check(
            "[10] end < start（9:00 に始まり 8:00 に終わる）は長さ 0 と同じく「9:00」",
            label(at(tk, 2026, 9, 28, 9), at(tk, 2026, 9, 28, 8)),
            "9:00"
        )
        check(
            "[10] 終日の予定（28日 0:00–29日 0:00）は「終日」",
            label(day28, at(tk, 2026, 9, 29), allDay: true),
            "終日"
        )
        check(
            "[10] 終日なら時刻は見ない（10:00–11:00 でも isAllDay なら「終日」）",
            label(at(tk, 2026, 9, 28, 10), at(tk, 2026, 9, 28, 11), allDay: true),
            "終日"
        )
        check(
            "[10] 何日もまたがる終日の予定の途中の日も「終日」（27日 0:00–30日 0:00 の 28日）",
            label(at(tk, 2026, 9, 27), at(tk, 2026, 9, 30), allDay: true),
            "終日"
        )

        // 時刻は渡した暦の時間帯で読む。東京の 28日 10:00–11:00 は、ニューヨークでは 27日 21:00–22:00。
        check(
            "[10] 時刻は渡した暦の時間帯で書く（東京の 10:00–11:00 をニューヨークの 27日の欄に出すと 21:00–22:00）",
            CalendarGrid.timeLabel(
                start: at(tk, 2026, 9, 28, 10), end: at(tk, 2026, 9, 28, 11),
                isAllDay: false, day: at(ny, 2026, 9, 27), calendar: ny
            ),
            "21:00\(dash)22:00"
        )
        func nyLabel(_ y: Int, _ m: Int, _ d: Int, _ start: Date, _ end: Date) -> String {
            CalendarGrid.timeLabel(start: start, end: end, isAllDay: false, day: at(ny, y, m, d), calendar: ny)
        }
        check(
            "[10] 夏時間の始まる日（ニューヨーク 3月8日）は時計どおりの時刻（1:30 EST–3:30 EDT → 1:30–3:30）",
            nyLabel(2026, 3, 8, at(ny, 2026, 3, 8, 1, 30), at(ny, 2026, 3, 8, 3, 30)),
            "1:30\(dash)3:30"
        )
        check(
            "[10] 23 時間しかない日（ニューヨーク 3月8日）の 23:00–翌日 0:30 は翌日へ続く（23:00–）",
            nyLabel(2026, 3, 8, at(ny, 2026, 3, 8, 23), at(ny, 2026, 3, 9, 0, 30)),
            "23:00\(dash)"
        )
        check(
            "[10] 25 時間ある日（ニューヨーク 11月1日）の 23:15–23:45 はその日の中の予定",
            nyLabel(2026, 11, 1, at(ny, 2026, 11, 1, 23, 15), at(ny, 2026, 11, 1, 23, 45)),
            "23:15\(dash)23:45"
        )
        check(
            "[10] 25 時間ある日（ニューヨーク 11月1日）でも翌日 0:00 に終わる予定は「23:00–0:00」",
            nyLabel(2026, 11, 1, at(ny, 2026, 11, 1, 23), at(ny, 2026, 11, 2)),
            "23:00\(dash)0:00"
        )

        // MARK: 性質 — 何年分もの月、7 通りの週の始まり、東京とニューヨークで

        // 2023〜2028 年の各月（閏年の 2024年・2028年の 2 月を含む）× 週の始まり 1〜7 × 2 つの時間帯。
        var gridCases = 0
        var notFortyTwo: [String] = []
        var notConsecutive: [String] = []
        var notMidnight: [String] = []
        var wrongHeadWeekday: [String] = []
        var firstNotInFirstWeek: [String] = []
        var lastDayMissing: [String] = []
        var dependsOnInstant: [String] = []
        var headerMismatch: [String] = []

        for zone in [tokyo, newYork] {
            for fw in 1...7 {
                let c = makeCalendar(zone, firstWeekday: fw)
                let header = CalendarGrid.weekdaySymbols(calendar: c)
                for y in 2023...2028 {
                    for m in 1...12 {
                        gridCases += 1
                        let name = "\(zone) 週の始まり=\(fw) \(y)年\(m)月"
                        let first = at(c, y, m, 1)
                        let nextMonth = c.date(byAdding: .month, value: 1, to: first)!
                        let lastDay = c.date(byAdding: .day, value: -1, to: nextMonth)!
                        let days = CalendarGrid.days(for: first, calendar: c)

                        if days.count != 42 {
                            notFortyTwo.append("\(name): \(days.count) 日")
                        }
                        if let i = days.indices.dropFirst().first(where: {
                            c.date(byAdding: .day, value: 1, to: days[$0 - 1]) != days[$0]
                        }) {
                            notConsecutive.append("\(name): \(stamp(c, days[i - 1])) の次が \(stamp(c, days[i]))")
                        }
                        if let bad = days.first(where: { !isMidnight(c, $0) }) {
                            notMidnight.append("\(name): \(stamp(c, bad))")
                        }
                        if let head = days.first, c.component(.weekday, from: head) != fw {
                            wrongHeadWeekday.append("\(name): 先頭 \(ymd(c, head)) の曜日が \(c.component(.weekday, from: head))")
                        }
                        if !days.prefix(7).contains(first) {
                            firstNotInFirstWeek.append("\(name): 最初の週 \(days.prefix(7).map { ymd(c, $0) })")
                        }
                        if !days.contains(lastDay) {
                            lastDayMissing.append("\(name): 末日 \(ymd(c, lastDay)) が無い")
                        }
                        let middle = at(c, y, m, 15, 12, 34, 56)
                        let lastInstant = nextMonth.addingTimeInterval(-1)
                        if CalendarGrid.days(for: middle, calendar: c) != days
                            || CalendarGrid.days(for: lastInstant, calendar: c) != days {
                            dependsOnInstant.append(name)
                        }
                        let columns = days.prefix(7).map {
                            c.veryShortStandaloneWeekdaySymbols[c.component(.weekday, from: $0) - 1]
                        }
                        if header != columns {
                            headerMismatch.append("\(name): 見出し \(header) / 列 \(columns)")
                        }
                    }
                }
            }
        }

        checkEvery("[1] どの月でも 42 日", cases: gridCases, notFortyTwo)
        checkEvery("[3] どの月でも 1 日ずつ連続", cases: gridCases, notConsecutive)
        checkEvery("[3][5] どの月でも、どの日も暦の時間帯での 0:00（夏時間の月を含む）", cases: gridCases, notMidnight)
        checkEvery("[4] どの月でも先頭は週の始まりの曜日", cases: gridCases, wrongHeadWeekday)
        checkEvery("[4] どの月でも 1日は最初の週にある", cases: gridCases, firstNotInFirstWeek)
        checkEvery("[1] どの月でも月の末日まで入る", cases: gridCases, lastDayMissing)
        checkEvery("[2] どの月でも、月の途中や月末 23:59:59 を渡しても 1日 0:00 と同じ表", cases: gridCases, dependsOnInstant)
        checkEvery("[4][6] どの月でも見出しの曜日と最初の週の各列の曜日が合う", cases: gridCases, headerMismatch)

        // 見出しは 7 つで、暦の記号を週の始まりから一周並べたもの。週の始まり 1〜7 × 日本語・英語。
        var symbolCases = 0
        var symbolsWrong: [String] = []
        for fw in 1...7 {
            for locale in ["ja_JP", "en_US"] {
                symbolCases += 1
                let c = makeCalendar(tokyo, firstWeekday: fw, locale: locale)
                let base = c.veryShortStandaloneWeekdaySymbols
                let expected = (0..<7).map { base[(fw - 1 + $0) % 7] }
                let actual = CalendarGrid.weekdaySymbols(calendar: c)
                if actual != expected {
                    symbolsWrong.append("\(locale) 週の始まり=\(fw): 期待 \(expected) 実際 \(actual)")
                }
            }
        }
        checkEvery("[6] どの週の始まり・地域でも、見出しは 7 つで週の始まりから一周", cases: symbolCases, symbolsWrong)

        // 2026 年の毎日（夏時間の切り替わる日を含む）× 東京とニューヨーク。
        var dayCases = 0
        var allDayLeaks: [String] = []
        var zeroLengthLeaks: [String] = []
        var untilMidnightLabel: [String] = []
        for zone in [tokyo, newYork] {
            let c = makeCalendar(zone)
            let jan1 = at(c, 2026, 1, 1)
            for i in 0..<365 {
                dayCases += 1
                let day = c.date(byAdding: .day, value: i, to: jan1)!
                let prev = c.date(byAdding: .day, value: -1, to: day)!
                let next = c.date(byAdding: .day, value: 1, to: day)!
                let around = [prev, day, next]

                let allDay = spread(day, next, over: around, c)
                if allDay != "・●・" { allDayLeaks.append("\(zone) \(ymd(c, day)): \(allDay)") }

                let zero = spread(day, day, over: around, c)
                if zero != "・●・" { zeroLengthLeaks.append("\(zone) \(ymd(c, day)): \(zero)") }

                let eleven = c.date(bySettingHour: 23, minute: 0, second: 0, of: day)!
                let text = CalendarGrid.timeLabel(start: eleven, end: next, isAllDay: false, day: day, calendar: c)
                if text != "23:00\(dash)0:00" { untilMidnightLabel.append("\(zone) \(ymd(c, day)): \(text)") }
            }
        }
        checkEvery("[7] どの日でも、終日の予定（0:00–翌日 0:00）はその日だけに出て前後の日に出ない", cases: dayCases, allDayLeaks)
        checkEvery("[8] どの日でも、0:00 ちょうどの長さ 0 の予定はその日だけに出る", cases: dayCases, zeroLengthLeaks)
        checkEvery("[10] どの日でも、23:00 から翌日 0:00 の予定は「23:00–0:00」", cases: dayCases, untilMidnightLabel)

        print(failures == 0 ? "\nすべて通った" : "\n\(failures) 件失敗")
        exit(failures == 0 ? 0 : 1)
    }
}
