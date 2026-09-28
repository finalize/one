import AppKit
import EventKit

/// カレンダーの小窓の状態。どの月を出しているか、どの日を選んでいるか、その予定。
///
/// 予定はカレンダー.app と同じところ（EventKit）から読む。iCloud・Google・Exchange など、
/// カレンダー.app に足してあるアカウントの予定がそのまま出る。読むだけで、書き換えない。
@MainActor
@Observable
final class CalendarModel {
    /// 予定を読む許可。
    enum Access {
        /// まだ聞いていない。小窓を初めて開いたときに聞く
        case notAsked
        case granted
        /// 断られた、または「予定を足すだけ」の許可しか無い（それでは読めない）
        case denied
    }

    /// 一覧に出す予定1つ分。EventKit の `EKEvent` をそのまま画面に渡さず、要る値だけを写す。
    struct Event: Identifiable {
        /// 繰り返しの予定は、どの回も同じ `eventIdentifier` を持つ。回ごとに見分けるため始まりも混ぜる。
        let id: String
        let identifier: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: NSColor
        /// どのカレンダーの予定か（`EKCalendar.calendarIdentifier`）。出すかどうか・祝日かを見分ける。
        let calendarID: String
    }

    /// カレンダー.app に入っているカレンダー1つ分。設定の窓に並べる。
    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        let color: NSColor
        /// アカウントの名前（iCloud、Google のアドレスなど）。設定の窓でこれごとにまとめる。
        let account: String
    }

    private(set) var access: Access
    /// 表に出している月（その月の1日の 0:00）。
    private(set) var month: Date
    /// 選んでいる日（0:00）。
    private(set) var selectedDay: Date
    /// 今日（0:00）。日付が変わったら入れ替える。
    private(set) var today: Date
    /// 表の日ごとの予定。キーはその日の 0:00。
    private(set) var eventsByDay: [Date: [Event]] = [:]
    /// 表の中の祝日（0:00）。祝日のカレンダーに終日の予定がある日。日曜と同じ赤で出す。
    private(set) var holidays: Set<Date> = []

    /// カレンダー.app に入っているカレンダー。アカウント、名前の順。
    private(set) var calendars: [CalendarInfo] = []

    /// 予定を出さないカレンダー。
    ///
    /// 出すほうではなく隠すほうを覚える。あとからカレンダーを足したとき、出る側で始まってほしいから。
    private(set) var hiddenCalendarIDs: Set<String>

    /// 祝日のカレンダー。nil は「なし」（祝日を赤くしない）。
    ///
    /// 一覧に出すかどうか（`hiddenCalendarIDs`）とは別に決まる。祝日の予定を一覧から隠したまま、
    /// 日だけ赤くできる。
    private(set) var holidayCalendarID: String?

    /// 暦。システム設定の「週の始まり」や地域を変えたら追いかけるよう、autoupdating にする。
    let calendar = Calendar.autoupdatingCurrent

    private let store = EKEventStore()

    private enum Keys {
        static let hidden = "hiddenCalendars"
        /// 空の文字列は「なし」を選んだ印。キーが無いのは、まだ選んでいない印（名前から推して選ぶ）。
        static let holiday = "holidayCalendar"
    }

    init() {
        let defaults = UserDefaults.standard
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
        holidayCalendarID = defaults.string(forKey: Keys.holiday).flatMap { $0.isEmpty ? nil : $0 }

        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        self.today = today
        selectedDay = today
        month = Self.firstOfMonth(today, calendar: .autoupdatingCurrent)
        access = Self.currentAccess()

        let center = NotificationCenter.default
        // カレンダー.app や同期で予定が変わった。
        center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // 日付が変わった（0:00 を過ぎた、スリープから覚めたら翌日だった）。
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToday() }
        }
    }

    /// 表に並べる 42 日。
    var days: [Date] { CalendarGrid.days(for: month, calendar: calendar) }

    var weekdaySymbols: [String] { CalendarGrid.weekdaySymbols(calendar: calendar) }

    func events(on day: Date) -> [Event] { eventsByDay[day] ?? [] }

    func isHoliday(_ day: Date) -> Bool { holidays.contains(day) }

    // MARK: - 設定の窓から

    /// 設定の窓を開いたときに呼ぶ。許可の状態とカレンダーの一覧を読み直す。
    /// 小窓を一度も開いていなくても、設定の窓に一覧を出したい。
    func refresh() {
        access = Self.currentAccess()
        reload()
    }

    func isShown(_ id: String) -> Bool { !hiddenCalendarIDs.contains(id) }

    func setShown(_ id: String, _ shown: Bool) {
        if shown { hiddenCalendarIDs.remove(id) } else { hiddenCalendarIDs.insert(id) }
        UserDefaults.standard.set(hiddenCalendarIDs.sorted(), forKey: Keys.hidden)
        reload()
    }

    func setHolidayCalendar(_ id: String?) {
        holidayCalendarID = id
        UserDefaults.standard.set(id ?? "", forKey: Keys.holiday)
        reload()
    }

    func isInShownMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: month, toGranularity: .month)
    }

    // MARK: - 開いたとき

    /// 小窓を開くたびに呼ぶ。今日の月に戻し、許可が無ければ聞き、予定を読み直す。
    ///
    /// 開いている間に届く変更は `EKEventStoreChanged` で拾うが、閉じている間は読み直さない。
    /// なので開くたびに読む。
    func prepareToShow() {
        refreshToday()
        month = Self.firstOfMonth(today, calendar: calendar)
        selectedDay = today
        access = Self.currentAccess()
        if access == .notAsked {
            requestAccess()
        } else {
            reload()
        }
    }

    // MARK: - 月を送る・日を選ぶ

    func showPreviousMonth() { moveMonth(by: -1) }
    func showNextMonth() { moveMonth(by: 1) }

    /// 今日の月に戻り、今日を選ぶ。
    func showToday() {
        month = Self.firstOfMonth(today, calendar: calendar)
        selectedDay = today
        reload()
    }

    /// 日を選ぶ。表の端に出ている前後の月の日なら、その月へ送る。
    func select(_ day: Date) {
        selectedDay = day
        if !isInShownMonth(day) {
            month = Self.firstOfMonth(day, calendar: calendar)
            reload()
        }
    }

    private func moveMonth(by value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: month) else { return }
        month = next
        // 送った先の月に今日があれば今日を、無ければ1日を選ぶ。
        selectedDay = isInShownMonth(today) ? today : next
        reload()
    }

    // MARK: - カレンダー.app で開く

    /// ほかのアプリ（カレンダー.app・システム設定）を開いた。小窓はメニューと同じ階層にいて、
    /// 開いたアプリの窓の上に残ってしまうので、これを合図に閉じる（`CalendarController`）。
    var onOpenedOtherApp: (() -> Void)?

    /// 予定をカレンダー.app で開く。
    ///
    /// 予定そのものを開く公開の手段は無い。カレンダー.app が受け付ける `ical://ekevent/…` の
    /// URL を使う（公開されていない形で、ほかのメニューバーのカレンダーも使っている）。
    func open(_ event: Event) {
        let id = event.identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.identifier
        guard let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
        onOpenedOtherApp?()
    }

    func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        onOpenedOtherApp?()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
            onOpenedOtherApp?()
        }
    }

    // MARK: - 読む

    /// 許可を聞く。まだ聞いていないときだけダイアログが出る。
    func requestAccess() {
        // [weak self] は外側のクロージャに付ける（`Camera.start` と同じ理由）。
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                log.notice("カレンダーの許可: \(granted ? "下りた" : "断られた", privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
                self.access = Self.currentAccess()
                self.reload()
            }
        }
    }

    /// カレンダーの一覧と、表の 42 日ぶんの予定を読み直す。
    private func reload() {
        guard access == .granted, let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else {
            eventsByDay = [:]
            holidays = []
            calendars = []
            return
        }
        reloadCalendars()

        // calendars に nil を渡すと全部になる。出さないカレンダーの予定もいったん読むのは、
        // 祝日のカレンダーを一覧から隠していても、祝日を赤くするのには使いたいから。
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)
        let events = store.events(matching: predicate).map { event in
            Event(
                id: "\(event.eventIdentifier ?? "")@\(event.startDate.timeIntervalSince1970)",
                identifier: event.calendarItemIdentifier,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                color: event.calendar.color,
                calendarID: event.calendar.calendarIdentifier
            )
        }

        let holidayEvents = events.filter { $0.isAllDay && $0.calendarID == holidayCalendarID }
        holidays = Set(days.filter { day in
            holidayEvents.contains { CalendarGrid.overlaps(start: $0.start, end: $0.end, day: day, calendar: calendar) }
        })

        let shown = events.filter { isShown($0.calendarID) }
        var byDay: [Date: [Event]] = [:]
        for day in days {
            let onDay = shown.filter { CalendarGrid.overlaps(start: $0.start, end: $0.end, day: day, calendar: calendar) }
            guard !onDay.isEmpty else { continue }
            // 終日の予定を先に、あとは始まる順。同じ時刻なら題の順にして、読み直すたびに並びが揺れないように。
            byDay[day] = onDay.sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.title < $1.title
            }
        }
        eventsByDay = byDay
    }

    private func reloadCalendars() {
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: $0.color, account: $0.source.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }

        // 祝日のカレンダーをまだ選んでいなければ、名前から推して選ぶ（「日本の祝日」など）。
        // 推した結果も覚える。あとで設定の窓で「なし」や別のものに変えられる。
        if UserDefaults.standard.object(forKey: Keys.holiday) == nil,
           let guess = calendars.first(where: { $0.title.contains("祝日") || $0.title.localizedCaseInsensitiveContains("holiday") }) {
            holidayCalendarID = guess.id
            UserDefaults.standard.set(guess.id, forKey: Keys.holiday)
        }
    }

    private func refreshToday() {
        let now = calendar.startOfDay(for: Date())
        if now != today { today = now }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notAsked
        case .fullAccess: .granted
        default: .denied
        }
    }

    private static func firstOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
