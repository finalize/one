import AppKit

/// 部品を作ってつなぐ。機能ごとの状態（Model）、カレンダーの小窓、設定の窓、メニューバーの ⌘。
///
/// ここには動きを書かない。⌘ の見た目とクリックは `StatusItemController`、右クリックのメニューは
/// `StatusMenu`、それぞれの機能はそれぞれのフォルダにある。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 起動が済んでから作る（下の applicationDidFinishLaunching）。`!` は「使うときには
    // 必ず入っている」という約束で、入っていなければそこで落ちる。
    private var model: AppModel!
    private var mirror: MirrorModel!
    private var calendarModel: CalendarModel!
    private var monitor: MonitorModel!
    private var calendar: CalendarController!
    private var settings: SettingsWindow!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        mirror = MirrorModel()
        calendarModel = CalendarModel()
        monitor = MonitorModel()
        calendar = CalendarController(model: calendarModel)
        settings = SettingsWindow(model: model, mirror: mirror, calendar: calendarModel, monitor: monitor)
        let menu = StatusMenu(model: model, mirror: mirror, monitor: monitor, settings: settings)
        statusItem = StatusItemController(model: model, monitor: monitor, calendar: calendar, menu: menu)
    }
}
