import Foundation

/// メニューバーに出す数字（ネットワーク・CPU・メモリ・ディスク）の計算と書き方。
///
/// 画面にも OS にも触らない。OS から読んだ累計の数（`SystemSampler`）を受け取って、
/// 1秒あたりの量や割合にし、メニューバーに並べる文字にする。なのでテストで確かめられる。
enum Monitor {
    /// メニューバーに出せるもの。並びはメニューバーの左からの順。
    enum Item: String, CaseIterable {
        case network
        case cpu
        case memory
        case disk
    }

    /// CPU が働いた時間の累計（`host_cpu_load_info` の `cpu_ticks`）。全部のコアを合わせた数。
    ///
    /// 数は 32 ビットで、いずれ一周して 0 に戻る（16 コアならひと月ほど）。差を取るときは
    /// 一周ぶんを足して考える（`cpuUsage`）。
    struct CPUTicks: Equatable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    // MARK: - 差から量にする

    /// 2回読んだ累計のバイト数から、1秒あたりのバイト数を出す。
    ///
    /// 累計が減っていたら nil（数が不明）。ネットワークの口が抜き差しされたり、数え直されたりすると
    /// 起きる。減ったぶんを大きな数として扱うと、一瞬だけとんでもない速度が出てしまう。
    static func rate(from old: UInt64, to new: UInt64, seconds: Double) -> Double? {
        guard new >= old, seconds > 0 else { return nil }
        return Double(new - old) / seconds
    }

    /// 2回読んだ `CPUTicks` から、その間の CPU の忙しさ（0〜1）を出す。
    ///
    /// 忙しさ = 働いた時間（user + system + nice）÷ 全部の時間（それに idle を足したもの）。
    /// 数が一周して戻っていても、32 ビットの引き算（`&-`）なら正しい差になる。
    /// 間に時間が進んでいなければ（全部の差が 0）nil。
    static func cpuUsage(from old: CPUTicks, to new: CPUTicks) -> Double? {
        let user = Double(new.user &- old.user)
        let system = Double(new.system &- old.system)
        let nice = Double(new.nice &- old.nice)
        let idle = Double(new.idle &- old.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return busy / total
    }

    /// 使っているメモリのバイト数。アクティビティモニタの「使用済みメモリ」に合わせた数え方で、
    /// アプリのメモリ（internal − purgeable）＋確保されているメモリ（wired）＋圧縮されたメモリ。
    ///
    /// 引数はどれもページの数（`vm_statistics64`）。purgeable が internal より多く見えることが
    /// あっても、アプリのメモリは 0 より小さくしない。
    static func memoryUsed(
        internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64
    ) -> UInt64 {
        // `internal` は Swift の予約語（アクセス修飾子）で名前に使えないので、Pages を付けて呼ぶ。
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (app + wiredPages + compressedPages) * pageSize
    }

    // MARK: - 書き方

    /// 1秒あたりのバイト数の書き方。「0 KB/s」「0.5 KB/s」「850 KB/s」「1.2 MB/s」「12 MB/s」「1.1 GB/s」。
    ///
    /// 単位は 1000 ごと（macOS の Finder やアクティビティモニタと同じ 10 進）で、いちばん小さい単位は
    /// KB/s。メニューバーで幅を取りすぎないよう、数字は3桁まで。10 未満だけ小数を1桁出す。
    static func speedText(_ bytesPerSecond: Double) -> String {
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var value = max(bytesPerSecond, 0) / 1000
        var unit = 0
        // 999.5 以上は四捨五入すると 1000 になり4桁に見えるので、次の単位に上げる。
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return "\(short(value)) \(units[unit])"
    }

    /// 割合（0〜1）の書き方。「0%」「12%」「100%」。範囲の外は端に寄せる。
    static func percentText(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// バイト数の書き方（ディスクの空き、メモリの量）。「850 MB」「9.8 GB」「120 GB」「1.2 TB」。
    /// 3桁まで、10 未満だけ小数1桁。
    ///
    /// `base` は単位の刻み。ディスクは Finder と同じ 1000 ごと。メモリは macOS がどこでも 1024 ごとで
    /// 数える（36 GB 積んだ Mac の「このMacについて」は 36 GB）ので、メモリには 1024 を渡す。
    /// 1000 ごとで数えると 38.7 GB になり、積んでいる量と食い違って見える。
    static func sizeText(_ bytes: Double, base: Double = 1000) -> String {
        let units = ["MB", "GB", "TB", "PB"]
        var value = max(bytes, 0) / (base * base)
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= base
            unit += 1
        }
        return "\(short(value)) \(units[unit])"
    }

    /// 10 未満なら小数1桁（9.95 以上は 10 に上がるので整数で）、それ以外は整数。
    /// 小数1桁で 0.0 になる量は「0」と書く。「0.0」は止まっているのに細かく見えて紛らわしい。
    ///
    /// どちらも四捨五入で、ちょうど半分は切り上げる（1.25 は 1.3、12.5 は 13）。`String(format: "%.1f")` に
    /// そのまま渡すと、ちょうど半分を偶数のほうへ寄せて 1.25 が 1.2 になり、整数のほうと揃わなかった。
    /// 先に 10 倍して `rounded()`（半分は切り上げ）で丸めてから書く。
    private static func short(_ value: Double) -> String {
        if value < 0.05 {
            return "0"
        }
        if value < 9.95 {
            return String(format: "%.1f", (value * 10).rounded() / 10)
        }
        return String(Int(value.rounded()))
    }

    // MARK: - メニューバーに並べる

    /// メニューバーの1行。`kind` は幅をそろえるための種類（`StatusImage` が使う）。
    struct Line: Equatable {
        enum Kind: Equatable {
            case down, up, cpu, memory, disk
        }
        var kind: Kind
        var text: String
    }

    /// 行を、上下2段の列に詰める。メニューバーの高さに入るのは2段まで。
    ///
    /// ネットワークの下り・上りはいつも同じ列の上と下に置く（2つで1つの項目なので）。
    /// ほかの行は、並んだ順に2つずつ詰める。1つ余ったら、その列は上の段だけ。
    static func columns(_ lines: [Line]) -> [[Line]] {
        var columns: [[Line]] = []
        var pending: [Line] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .down, index + 1 < lines.count, lines[index + 1].kind == .up {
                if !pending.isEmpty { columns.append(pending); pending = [] }
                columns.append([line, lines[index + 1]])
                index += 2
                continue
            }
            pending.append(line)
            if pending.count == 2 { columns.append(pending); pending = [] }
            index += 1
        }
        if !pending.isEmpty { columns.append(pending) }
        return columns
    }
}
