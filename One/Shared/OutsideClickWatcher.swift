import AppKit

/// One の窓の外がクリックされたら知らせる。鏡とカレンダーの小窓を、外のクリックで閉じるのに使う。
///
/// 窓がキーでなくなったこと（resignKey）では判定しない。フォーカスを奪わないパネルは
/// キーになったりならなかったりが状況で揺れるうえ、ノッチをクリックしたときに
/// 「閉じた直後にトグルでまた開く」が起きやすい。
///
/// グローバルモニタは **他のアプリ宛て**のクリックしか受け取らない。ノッチの小窓や小窓そのもの
/// （鏡の右クリックのメニュー、カレンダーの日）は One の窓なのでここに来ず、トグルとぶつからない。
/// ただしメニューバーの One のアイコン（⌘）へのクリックは、One のものなのにここに来る
/// （macOS 27 で確かめた）。気にするなら `ignoredArea` でアイコンの上を外す。
/// マウスのクリックを見るだけなら、アクセシビリティの許可は要らない。
@MainActor
final class OutsideClickWatcher {
    /// 外がクリックされた。
    var onClick: (() -> Void)?

    /// 外のクリックとみなさない範囲（画面の座標）。
    var ignoredArea: (() -> NSRect?)?

    private var monitor: Any?

    /// 見張るか。窓を出したら true、隠したら false にする。
    var isActive = false {
        didSet {
            if isActive, monitor == nil {
                monitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let area = self.ignoredArea?(), area.contains(NSEvent.mouseLocation) { return }
                        self.onClick?()
                    }
                }
            } else if !isActive, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
