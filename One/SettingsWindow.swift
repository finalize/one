import AppKit
import SwiftUI

/// 設定の窓。上にアイコン付きのタブが並ぶ、システム設定の各アプリでおなじみの形。
///
/// タブは `NSTabViewController` の `.toolbar` の形で組む。SwiftUI の `Settings` シーンが
/// 裏でしていることと同じで、見た目も同じになる。各タブの中身は SwiftUI のまま
/// （`SettingsView.swift`）、`NSHostingController` で包んで載せる。
@MainActor
final class SettingsWindow {
    private let model: AppModel
    private let mirror: MirrorModel
    private let calendar: CalendarModel
    /// 閉じても捨てずに持っておく。次に開いたとき、前に見ていたタブのまま出る。
    private var window: NSWindow?

    init(model: AppModel, mirror: MirrorModel, calendar: CalendarModel) {
        self.model = model
        self.mirror = mirror
        self.calendar = calendar
    }

    func show() {
        // カレンダーの許可や一覧は、システム設定やカレンダー.app で変わっているかもしれない。
        calendar.refresh()
        let window = window ?? makeWindow()
        self.window = window
        // One はふだん前面のアプリではない。前に出さないと、窓が前にいるアプリの窓の
        // 後ろに隠れる（SwiftUI の Settings で開いていたころに確かめた）。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(page("一般", "gearshape", GeneralSettings(model: model, calendar: calendar)))
        tabs.addTabViewItem(page("英かな", "command", InputSettings(model: model)))
        tabs.addTabViewItem(page("ウィンドウ", "uiwindow.split.2x1", WindowSettings(model: model)))
        tabs.addTabViewItem(page("鏡", "web.camera", MirrorSettings(mirror: mirror)))
        tabs.addTabViewItem(page("カレンダー", "calendar", CalendarSettings(model: model, calendar: calendar)))

        let window = NSWindow(contentViewController: tabs)
        // 大きさは中身が決める。端を掴んで変えられないように、resizable を外す。
        window.styleMask = [.titled, .closable]
        window.title = tabs.tabViewItems.first?.label ?? ""
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func page(_ label: String, _ symbol: String, _ content: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: content.settingsPage())
        // SwiftUI の中身の大きさを、窓の大きさの手がかり（preferredContentSize）として外へ伝える。
        host.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// タブを切り替えたら、窓の題を今のタブの名前にする（システム設定の各アプリと同じ）。
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? ""
    }
}
