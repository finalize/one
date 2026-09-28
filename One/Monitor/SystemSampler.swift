import Darwin
import Foundation

/// OS から、CPU・メモリ・ネットワーク・ディスクの今の数を読む。
///
/// どれも公開されている仕組み（Mach の `host_statistics`、`sysctl`、`URL` の資源の値）だけを使う。
/// 温度や GPU の使用率は、公開されていない仕組み（SMC など）が要るので読まない。
///
/// ここは累計や今の値を読むだけ。1秒あたりの量や割合にするのは `Monitor`。
enum SystemSampler {
    /// `mach_host_self()` は呼ぶたびに参照を1つ増やすので、一度だけ取って使い回す。
    private static let host = mach_host_self()

    /// CPU が働いた時間の累計。読めなければ nil。
    static func cpuTicks() -> Monitor.CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        // C の API は「整数の並び」として受け取る。構造体の置き場所を、その形に見立てて渡す。
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks は C の配列で、Swift からは4つ組（タプル）に見える。並びは CPU_STATE_* の順。
        let ticks = info.cpu_ticks
        return Monitor.CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    /// 使っているメモリと、積んでいるメモリ（どちらもバイト）。読めなければ nil。
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let used = Monitor.memoryUsed(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(vm_kernel_page_size)
        )
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// ネットワークで受け取った・送ったバイト数の累計。読めなければ nil。
    ///
    /// 数えるのは、名前が `en` で始まる口（Wi-Fi・有線・iPhone のテザリングなど）だけ。
    /// VPN（utun）は、同じ通信を暗号化の前と後で2回数えることになる。AirDrop（awdl・llw）や
    /// ブリッジも、実際の口の通信と重なる。ループバック（lo0）は Mac の中だけの通信。
    ///
    /// 口ごとに `sysctl` の `net.link.generic.ifdata`（ifmib）で読む。`netstat -ib` と同じ数になる
    /// （確かめた）。`getifaddrs` の数（`if_data`）は 32 ビットで、4 GB ごとに 0 に戻る。
    /// `NET_RT_IFLIST2` も試したが、64 ビットの入れ物なのに上の桁を落とした数が返った
    /// （10,283,094,716 のところ 1,693,167,616。2³² の2倍を引いた数）。
    static func networkBytes() -> (received: UInt64, sent: UInt64)? {
        guard let list = if_nameindex() else { return nil }
        defer { if_freenameindex(list) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        // 口の一覧は、if_index が 0 の要素で終わる C の配列。
        var index = 0
        while list[index].if_index != 0 {
            let entry = list[index]
            index += 1
            guard String(cString: entry.if_name).hasPrefix("en") else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(entry.if_index), IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { continue }
            received += data.ifmd_data.ifi_ibytes
            sent += data.ifmd_data.ifi_obytes
        }
        return (received, sent)
    }

    /// 起動ディスクの空き（バイト）。読めなければ nil。
    ///
    /// macOS が空けられる分（一時ファイルなど）も含めた量（`volumeAvailableCapacityForImportantUsage`）。
    static func diskFree() -> Int64? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
