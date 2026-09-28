import AppKit

/// メニューバーと右クリックのメニューに出す数字（ネットワーク・CPU・メモリ・ディスク）を
/// 1秒ごとに測って持つ。
///
/// どこにも出さない項目は測らない。ディスプレイが眠っている間も測らない（見る人がいない）。
@MainActor
@Observable
final class MonitorModel {
    /// 数字を出す場所。何を出すかは場所ごとに、設定の窓の「モニタ」タブで選ぶ。
    enum Place: CaseIterable {
        /// メニューバーの ⌘ の右。2段の小さな字
        case menuBar
        /// ⌘ の右クリックのメニューの上のほう。細かい数（メモリの GB など）も出す
        case menu
    }

    /// メニューバーに出すもの。
    private(set) var barItems: [Monitor.Item]
    /// 右クリックのメニューに出すもの。
    private(set) var menuItems: [Monitor.Item]

    /// 1秒あたりの受信・送信のバイト数。まだ2回測っていない、または数が戻ったときは nil。
    private(set) var downPerSecond: Double?
    private(set) var upPerSecond: Double?
    /// CPU の忙しさ（0〜1）。
    private(set) var cpu: Double?
    private(set) var memory: (used: UInt64, total: UInt64)?
    /// 起動ディスクの空き（バイト）。
    private(set) var diskFree: Int64?

    private var timer: Timer?
    private var screensAsleep = false
    private var lastCPU: Monitor.CPUTicks?
    private var lastNetwork: (received: UInt64, sent: UInt64, at: Date)?
    /// ディスクの空きは速くは変わらないので、10回に1回だけ読む。
    private var ticksUntilDisk = 0

    /// メニューバーのほうは、場所を分ける前からの名前のまま（選んであったものを引き継ぐ）。
    private static func key(for place: Place) -> String {
        switch place {
        case .menuBar: "monitorItems"
        case .menu: "monitorMenuItems"
        }
    }

    init() {
        barItems = Self.saved(for: .menuBar)
        menuItems = Self.saved(for: .menu)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.updateTimer()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.updateTimer()
            }
        }
        updateTimer()
    }

    /// 保存が無ければ全部出す。空の並びは「何も出さない」を選んだ印なので、そのまま使う。
    private static func saved(for place: Place) -> [Monitor.Item] {
        let saved = UserDefaults.standard.stringArray(forKey: key(for: place))
        return saved.map { $0.compactMap(Monitor.Item.init(rawValue:)) } ?? Monitor.Item.allCases
    }

    // MARK: - 設定の窓から

    func items(in place: Place) -> [Monitor.Item] {
        switch place {
        case .menuBar: barItems
        case .menu: menuItems
        }
    }

    func isShown(_ item: Monitor.Item, in place: Place) -> Bool { items(in: place).contains(item) }

    /// 出す・出さないを切り替える。並びはいつも `Monitor.Item.allCases` の順（メニューバーの左から）。
    func setShown(_ item: Monitor.Item, in place: Place, _ shown: Bool) {
        var set = Set(items(in: place))
        if shown { set.insert(item) } else { set.remove(item) }
        let items = Monitor.Item.allCases.filter(set.contains)
        switch place {
        case .menuBar: barItems = items
        case .menu: menuItems = items
        }
        UserDefaults.standard.set(items.map(\.rawValue), forKey: Self.key(for: place))
        if !measured.contains(item) { forget(item) }
        updateTimer()
    }

    /// 測るもの。どちらかの場所に出しているもの。
    private var measured: Set<Monitor.Item> { Set(barItems + menuItems) }

    /// どこにも出さなくなったものの値を捨てる。残すと、説明に古い数が出続ける。
    /// また出したときは、2回測るまで「–」から始まる。
    private func forget(_ item: Monitor.Item) {
        switch item {
        case .network:
            downPerSecond = nil
            upPerSecond = nil
            lastNetwork = nil
        case .cpu:
            cpu = nil
            lastCPU = nil
        case .memory:
            memory = nil
        case .disk:
            diskFree = nil
            ticksUntilDisk = 0
        }
    }

    // MARK: - 出す形

    /// メニューバーに並べる行。まだ測れていないものは「–」。
    var lines: [Monitor.Line] {
        barItems.flatMap { item -> [Monitor.Line] in
            switch item {
            case .network:
                return [
                    .init(kind: .down, text: "↓ " + (downPerSecond.map(Monitor.speedText) ?? "–")),
                    .init(kind: .up, text: "↑ " + (upPerSecond.map(Monitor.speedText) ?? "–")),
                ]
            case .cpu:
                return [.init(kind: .cpu, text: "CPU " + (cpu.map(Monitor.percentText) ?? "–"))]
            case .memory:
                let text = memory.map { Monitor.percentText(Double($0.used) / Double($0.total)) } ?? "–"
                return [.init(kind: .memory, text: "メモリ " + text)]
            case .disk:
                return [.init(kind: .disk, text: "空き " + (diskFree.map { Monitor.sizeText(Double($0)) } ?? "–"))]
            }
        }
    }

    /// 細かい数を1項目1行で。メニューバーに入りきらない数（メモリの GB）も出す。
    ///
    /// `.menu` は右クリックのメニューに、`.menuBar` は ⌘ にポインタを載せたときの説明に使う
    /// （メニューバーに出ている数の細かい版）。
    ///
    /// 出しているものだけを、メニューバーと同じ順に。まだ測れていないものも行は出して「–」にする。
    /// 行の数が途中で変わると、メニューを開いている間に項目が増えたり減ったりしてしまう。
    func detailLines(for place: Place) -> [String] {
        items(in: place).map { item in
            switch item {
            case .network:
                let down = downPerSecond.map(Monitor.speedText) ?? "–"
                let up = upPerSecond.map(Monitor.speedText) ?? "–"
                return "↓ 受信 \(down)　↑ 送信 \(up)"
            case .cpu:
                return "CPU \(cpu.map(Monitor.percentText) ?? "–")"
            case .memory:
                guard let memory else { return "メモリ –" }
                let used = Monitor.sizeText(Double(memory.used), base: 1024)
                let total = Monitor.sizeText(Double(memory.total), base: 1024)
                return "メモリ \(used) / \(total)（\(Monitor.percentText(Double(memory.used) / Double(memory.total)))）"
            case .disk:
                return "起動ディスクの空き \(diskFree.map { Monitor.sizeText(Double($0)) } ?? "–")"
            }
        }
    }

    // MARK: - 測る

    private func updateTimer() {
        let wants = !measured.isEmpty && !screensAsleep
        if wants, timer == nil {
            ticksUntilDisk = 0
            sample()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            // 少しずれてもよいと伝えると、macOS がほかの仕事とまとめて起こせて、電池の減りが少ない。
            timer.tolerance = 0.2
            // メニューを開いている間（イベントの追跡中）も止まらないように、common の型で回す。
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wants, let timer {
            timer.invalidate()
            self.timer = nil
            // 次に始めたとき、止まっていた間の差を1秒ぶんとして割らないように、前の値を捨てる。
            lastCPU = nil
            lastNetwork = nil
        }
    }

    /// 1回測る。どこにも出していないものは読まない。
    private func sample() {
        let measured = measured
        if measured.contains(.network), let now = SystemSampler.networkBytes() {
            let at = Date()
            if let last = lastNetwork {
                let seconds = at.timeIntervalSince(last.at)
                downPerSecond = Monitor.rate(from: last.received, to: now.received, seconds: seconds)
                upPerSecond = Monitor.rate(from: last.sent, to: now.sent, seconds: seconds)
            }
            lastNetwork = (now.received, now.sent, at)
        }
        if measured.contains(.cpu), let now = SystemSampler.cpuTicks() {
            if let lastCPU { cpu = Monitor.cpuUsage(from: lastCPU, to: now) }
            lastCPU = now
        }
        if measured.contains(.memory) {
            memory = SystemSampler.memory()
        }
        if measured.contains(.disk) {
            if ticksUntilDisk == 0 {
                diskFree = SystemSampler.diskFree()
                ticksUntilDisk = 10
            }
            ticksUntilDisk -= 1
        }
    }
}
