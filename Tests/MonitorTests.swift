import Foundation

// メニューバーに出す数字の計算と書き方（Monitor）を、決めごとから確かめる。
//
// 実装は見ずに、決めごと（仕様）の一文ずつをケースにしてある。テスト名の先頭の [n] は決めごとの番号。
// 値で固定する例に加えて、たくさんの入力で成り立つはずの性質も見る。
// OS から読んだ数（累計のバイト数・CPU の tick・ページ数）は引数で渡すので、実際の CPU もネットワークも要らない。
// この Mac の地域や時刻にも依らない（Date() も Locale.current も使わない）。

private var failures = 0

private func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name)  期待=\(expected) 実際=\(actual)")
}

private typealias Ticks = Monitor.CPUTicks
private typealias Line = Monitor.Line
private typealias Kind = Monitor.Line.Kind

// 性質を見るための乱数。種を固定して、毎回同じ入力で試す（splitmix64）。
private struct MonitorTestRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 以上 1 未満
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func u32() -> UInt32 { UInt32(truncatingIfNeeded: next()) }
    /// 0 以上 n 未満
    mutating func below(_ n: UInt32) -> UInt32 { UInt32(next() % UInt64(n)) }
}

// MARK: - 書き方（6 と 8）の性質

/// 「数字だけ、小数点があれば後ろは1桁」の形か。
private func isNumeral(_ s: Substring) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    let digits = { (p: Substring) in !p.isEmpty && p.allSatisfy { ("0"..."9").contains($0) } }
    switch parts.count {
    case 1: return digits(parts[0])
    case 2: return digits(parts[0]) && digits(parts[1]) && parts[1].count == 1
    default: return false
    }
}

/// 性質を見る値。0、各桁を仮数 0.01 刻みで、対数で一様な乱数、境目（0.05・9.95・999.5 など）のちょうどと隣の数。
/// どれも 0 以上 limit 未満。
private func formatSamples(scales: [Double], limit: Double, seed: UInt64) -> [Double] {
    var values: [Double] = [0]
    var decade = 1.0
    while decade < limit {
        for i in 100..<1000 { values.append(Double(i) / 100 * decade) }
        decade *= 10
    }
    var random = MonitorTestRandom(seed: seed)
    let top = log10(limit)
    for _ in 0..<20_000 { values.append(pow(10, random.unit() * top)) }
    for scale in scales {
        for mark in [0.05, 0.5, 1, 9.95, 10, 99.5, 999.5] {
            let v = mark * scale
            values += [v.nextDown, v, v.nextUp]
        }
    }
    return values.filter { $0 >= 0 && $0 < limit }.sorted()
}

/// 6 と 8 の書き方が、たくさんの値で守るはずの性質。
/// units は小さい順、scales は各単位の 1 あたりのバイト数。
/// 違反があれば最初の1つを「値 → 書いた文字列」で出す。
private func checkFormatProperties(
    _ tag: String,
    units: [String],
    scales: [Double],
    values: [Double],
    format: (Double) -> String
) {
    var badShape: String?
    var badDigits: String?
    var badDecimal: String?
    var badInteger: String?
    var badPromotion: String?
    var badError: String?
    var badOrder: String?
    var previous: (value: Double, text: String, shown: Double)?

    for v in values {
        let text = format(v)
        let example = "\(v) → \"\(text)\""
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let unitIndex = units.firstIndex(of: String(parts[1])),
              isNumeral(parts[0]),
              let number = Double(parts[0])
        else {
            badShape = badShape ?? example
            continue
        }
        let hasDecimal = parts[0].contains(".")
        if parts[0].filter({ $0 != "." }).count > 3 { badDigits = badDigits ?? example }
        // 小数が付くのは 10 未満のときだけ。0.0 は「0」と書くので、小数付きは 0.1 以上。
        if hasDecimal && !(number >= 0.1 && number < 10) { badDecimal = badDecimal ?? example }
        // 10 未満は小数1桁で書くので、小数の無い数は「0」か 10 以上。
        if !hasDecimal && !(number == 0 || number >= 10) { badInteger = badInteger ?? example }
        // 上の単位に上げるのは、下の単位で四捨五入して 1000 になるときだけ。上げた先では 1.0 以上。
        if unitIndex > 0 && number < 1 { badPromotion = badPromotion ?? example }
        // 書いた数は、元の値から丸めの幅（小数1桁と「0」は 0.05、整数は 0.5）以内。
        let scale = scales[unitIndex]
        let shown = number * scale
        let halfStep = (hasDecimal || number == 0) ? 0.05 : 0.5
        if abs(shown - v) > halfStep * scale * (1 + 1e-9) { badError = badError ?? example }
        // 大きい値ほど、書いた量も小さくならない。
        if let p = previous, shown < p.shown {
            badOrder = badOrder ?? "\(p.value) → \"\(p.text)\" の次に \(example)"
        }
        previous = (v, text, shown)
    }

    let unitList = units.joined(separator: "・")
    check("\(tag) 多くの値で、形は「数 単位」、単位は \(unitList) のどれか", badShape ?? "なし", "なし")
    check("\(tag) 多くの値で、数字の部分は3桁以内（小数点を除く）", badDigits ?? "なし", "なし")
    check("\(tag) 多くの値で、小数が付くのは 10 未満のときだけ、0.0 は出ない", badDecimal ?? "なし", "なし")
    check("\(tag) 多くの値で、小数の無い数は 0 か 10 以上", badInteger ?? "なし", "なし")
    check("\(tag) 多くの値で、上の単位の数は 1.0 以上（早く上げすぎない）", badPromotion ?? "なし", "なし")
    check("\(tag) 多くの値で、書いた量は元の値から丸めの幅以内", badError ?? "なし", "なし")
    check("\(tag) 多くの値で、大きい値ほど書いた量も小さくならない", badOrder ?? "なし", "なし")
}

// MARK: - 列（9）

private func lines(_ kinds: [Kind]) -> [Line] {
    kinds.map { Line(kind: $0, text: "\($0)") }
}

/// 列を、各行の text で読む。
private func columnTexts(_ kinds: [Kind]) -> [[String]] {
    Monitor.columns(lines(kinds)).map { $0.map(\.text) }
}

@main
struct MonitorTests {
    static func main() {
        // 途中で止まっても（整数の溢れなど）、そこまでの結果が見えるように1行ずつ出す。
        setvbuf(stdout, nil, _IOLBF, 0)

        // MARK: [1] 累計のバイト数から 1 秒あたりの速さ

        check("[1] 2 秒で 2000 バイト増えたら 1000 B/s", Monitor.rate(from: 1000, to: 3000, seconds: 2), 1000)
        check("[1] 0.5 秒で 1,500,000 バイトなら 3,000,000 B/s", Monitor.rate(from: 0, to: 1_500_000, seconds: 0.5), 3_000_000)
        check("[1] 増えていなければ 0", Monitor.rate(from: 5000, to: 5000, seconds: 1), 0)
        check("[1] 1 増えたら 1（減った境目の直後）", Monitor.rate(from: 5000, to: 5001, seconds: 1), 1)

        // ここが設計の判断。累計が戻ったのを大きな差として扱うと、一瞬だけ巨大な速度が出る。
        check("[1] 累計が 1 でも減っていたら nil（境目の直前）", Monitor.rate(from: 5000, to: 4999, seconds: 1), nil)
        check("[1] 累計が 0 に戻ったら nil", Monitor.rate(from: 10_000_000, to: 0, seconds: 1), nil)
        // CPU の tick（[3]）と違い、バイト数は一周として扱わない。
        check("[1] 64 ビットの最大から 0 に戻っても nil（一周とはみなさない）", Monitor.rate(from: UInt64.max, to: 0, seconds: 1), nil)

        check("[1] 秒数が 0 なら nil", Monitor.rate(from: 0, to: 1000, seconds: 0), nil)
        check("[1] 秒数が負なら nil", Monitor.rate(from: 0, to: 1000, seconds: -1), nil)
        check("[1] 秒数が 0 より少しでも大きければ出す（0.25 秒で 1000 なら 4000）", Monitor.rate(from: 0, to: 1000, seconds: 0.25), 4000)
        check("[1] 秒数が 0 で増えてもいないときも nil", Monitor.rate(from: 7, to: 7, seconds: 0), nil)

        // 差は new − old。累計が 2^53 を超えると、先に Double にしてから引くと差がずれる。
        let big = UInt64(1) << 60
        check("[1] 累計が 2^53 を超えていても差はそのまま", Monitor.rate(from: big, to: big + 1000, seconds: 1), 1000)

        // MARK: [2] CPU の忙しさ = 働いた時間 ÷ 全部の時間

        let zero = Ticks(user: 0, system: 0, idle: 0, nice: 0)
        check(
            "[2] user 30・system 10・nice 10 働き、idle 50 なら 0.5",
            Monitor.cpuUsage(from: zero, to: Ticks(user: 30, system: 10, idle: 50, nice: 10)),
            0.5
        )
        check("[2] user は働いた時間に入る", Monitor.cpuUsage(from: zero, to: Ticks(user: 25, system: 0, idle: 75, nice: 0)), 0.25)
        check("[2] system は働いた時間に入る", Monitor.cpuUsage(from: zero, to: Ticks(user: 0, system: 25, idle: 75, nice: 0)), 0.25)
        check("[2] nice は働いた時間に入る", Monitor.cpuUsage(from: zero, to: Ticks(user: 0, system: 0, idle: 75, nice: 25)), 0.25)
        check("[2] idle だけ進んだら 0", Monitor.cpuUsage(from: zero, to: Ticks(user: 0, system: 0, idle: 100, nice: 0)), 0)
        check("[2] idle が進まなければ 1", Monitor.cpuUsage(from: zero, to: Ticks(user: 40, system: 30, idle: 0, nice: 30)), 1)
        // 累計そのもの（750 ÷ 1100）ではなく、その間の差で数える。
        check(
            "[2] 使うのは累計でなく2回の差",
            Monitor.cpuUsage(
                from: Ticks(user: 100, system: 200, idle: 300, nice: 400),
                to: Ticks(user: 130, system: 210, idle: 350, nice: 410)
            ),
            0.5
        )

        // MARK: [3] 32 ビットで一周した tick

        // ここが設計の判断。どのフィールドが一周しても同じに扱う。
        let nearMax = UInt32.max - 9  // ここから 10 まで進むと差は 20
        check(
            "[3] user が一周しても差は一周ぶんを足した 20",
            Monitor.cpuUsage(from: Ticks(user: nearMax, system: 0, idle: 0, nice: 0), to: Ticks(user: 10, system: 0, idle: 60, nice: 0)),
            0.25
        )
        check(
            "[3] system が一周しても同じ",
            Monitor.cpuUsage(from: Ticks(user: 0, system: nearMax, idle: 0, nice: 0), to: Ticks(user: 0, system: 10, idle: 60, nice: 0)),
            0.25
        )
        check(
            "[3] nice が一周しても同じ",
            Monitor.cpuUsage(from: Ticks(user: 0, system: 0, idle: 0, nice: nearMax), to: Ticks(user: 0, system: 0, idle: 60, nice: 10)),
            0.25
        )
        check(
            "[3] idle が一周しても同じ",
            Monitor.cpuUsage(from: Ticks(user: 0, system: 0, idle: nearMax, nice: 0), to: Ticks(user: 60, system: 0, idle: 10, nice: 0)),
            0.75
        )
        check(
            "[3] 全部のフィールドが一度に一周しても同じ",
            Monitor.cpuUsage(
                from: Ticks(user: nearMax, system: nearMax, idle: nearMax, nice: nearMax),
                to: Ticks(user: 10, system: 10, idle: 10, nice: 10)
            ),
            0.75
        )
        check(
            "[3] 最大から 0 は差 1（一周した直後）",
            Monitor.cpuUsage(from: Ticks(user: UInt32.max, system: 0, idle: 0, nice: 0), to: Ticks(user: 0, system: 0, idle: 1, nice: 0)),
            0.5
        )
        check(
            "[3] 最大の 1 つ手前から最大は差 1（一周する直前）",
            Monitor.cpuUsage(from: Ticks(user: UInt32.max - 1, system: 0, idle: 0, nice: 0), to: Ticks(user: UInt32.max, system: 0, idle: 1, nice: 0)),
            0.5
        )
        check(
            "[3] 同じ値のままなら差は 0（一周ぶんではない）",
            Monitor.cpuUsage(from: Ticks(user: UInt32.max, system: 5, idle: 0, nice: 0), to: Ticks(user: UInt32.max, system: 5, idle: 1, nice: 0)),
            0
        )

        // 古い値をどこに置いても、差が同じなら同じ割合になる。半分は一周の手前に置いて 0 をまたがせる。
        do {
            var random = MonitorTestRandom(seed: 2)
            var bad: String?
            for n in 0..<20_000 {
                let start = { () -> UInt32 in n % 2 == 0 ? UInt32.max - random.below(2_000_000) : random.u32() }
                let old = Ticks(user: start(), system: start(), idle: start(), nice: start())
                let d = (user: random.below(1_000_000), system: random.below(1_000_000), idle: random.below(1_000_000) + 1, nice: random.below(1_000_000))
                let new = Ticks(user: old.user &+ d.user, system: old.system &+ d.system, idle: old.idle &+ d.idle, nice: old.nice &+ d.nice)
                let busy = Double(d.user) + Double(d.system) + Double(d.nice)
                let expected = busy / (busy + Double(d.idle))
                let actual = Monitor.cpuUsage(from: old, to: new)
                if actual == nil || abs(actual! - expected) > 1e-12 {
                    bad = bad ?? "\(old) → \(new): 期待 \(expected)、実際 \(String(describing: actual))"
                }
            }
            check("[3] 古い値がどこにあっても（0 をまたいでも）、差から求めた割合になる", bad ?? "なし", "なし")
        }

        // MARK: [4] 時間が進んでいなければ nil

        check("[4] 全部 0 のまま", Monitor.cpuUsage(from: zero, to: zero), nil)
        let same = Ticks(user: 100, system: 200, idle: 300, nice: 400)
        check("[4] 全部の差が 0", Monitor.cpuUsage(from: same, to: same), nil)
        let maxed = Ticks(user: .max, system: .max, idle: .max, nice: .max)
        check("[4] 全部が最大のまま（一周ぶんとは数えない）", Monitor.cpuUsage(from: maxed, to: maxed), nil)
        check("[4] idle が 1 だけ進んだら 0（nil の直後）", Monitor.cpuUsage(from: same, to: Ticks(user: 100, system: 200, idle: 301, nice: 400)), 0)
        check("[4] nice が 1 だけ進んだら 1（nil の直後）", Monitor.cpuUsage(from: same, to: Ticks(user: 100, system: 200, idle: 300, nice: 401)), 1)

        // MARK: [5] 使用済みメモリ

        // (1000 − 200) + 300 + 100 = 1200 ページ。どれか1つを落とすと 1100・900・1400 になり区別がつく。
        check(
            "[5] (internal − purgeable) ＋ wired ＋ compressed のページ数 × ページの大きさ",
            Monitor.memoryUsed(internalPages: 1000, purgeablePages: 200, wiredPages: 300, compressedPages: 100, pageSize: 16384),
            1200 * 16384
        )
        check(
            "[5] ページの大きさが 4096 でも同じ数え方",
            Monitor.memoryUsed(internalPages: 1000, purgeablePages: 200, wiredPages: 300, compressedPages: 100, pageSize: 4096),
            1200 * 4096
        )
        check(
            "[5] purgeable が internal より 1 少なければ 1 ページ残る（境目の直前）",
            Monitor.memoryUsed(internalPages: 500, purgeablePages: 499, wiredPages: 300, compressedPages: 100, pageSize: 4096),
            401 * 4096
        )
        check(
            "[5] purgeable が internal と同じなら 0",
            Monitor.memoryUsed(internalPages: 500, purgeablePages: 500, wiredPages: 300, compressedPages: 100, pageSize: 4096),
            400 * 4096
        )
        check(
            "[5] purgeable が internal より 1 多くても負にしない（境目の直後）",
            Monitor.memoryUsed(internalPages: 500, purgeablePages: 501, wiredPages: 300, compressedPages: 100, pageSize: 4096),
            400 * 4096
        )
        // 余った purgeable（200 ページ）を wired や compressed から引かない。
        check(
            "[5] purgeable が多くても、wired と compressed はそのまま数える",
            Monitor.memoryUsed(internalPages: 100, purgeablePages: 300, wiredPages: 50, compressedPages: 25, pageSize: 4096),
            75 * 4096
        )
        check(
            "[5] 何も無ければ 0",
            Monitor.memoryUsed(internalPages: 0, purgeablePages: 0, wiredPages: 0, compressedPages: 0, pageSize: 16384),
            0
        )

        // MARK: [6] 速さの書き方

        check("[6] 0 B/s は 0 KB/s", Monitor.speedText(0), "0 KB/s")
        check("[6] 30 B/s も 0 KB/s（0.0 と書かない）", Monitor.speedText(30), "0 KB/s")
        check("[6] 49 B/s は 0 KB/s（0.05 の直前）", Monitor.speedText(49), "0 KB/s")
        check("[6] 50 B/s は 0.1 KB/s（0.05 の境目）", Monitor.speedText(50), "0.1 KB/s")
        check("[6] 500 B/s は 0.5 KB/s", Monitor.speedText(500), "0.5 KB/s")
        check("[6] 1000 B/s は 1.0 KB/s（10 未満は割り切れても小数1桁）", Monitor.speedText(1000), "1.0 KB/s")
        check("[6] 1,234 B/s は 1.2 KB/s", Monitor.speedText(1234), "1.2 KB/s")
        check("[6] 1,249 B/s は 1.2 KB/s", Monitor.speedText(1249), "1.2 KB/s")
        // 決めごと 6 は小数1桁の丸め方を書いていなかった。整数と割合に合わせて、ちょうど半分は
        // 切り上げと決めた（2026-09-28）。実装は偶数のほうへ寄せていて（1.2）、直した。
        check("[6] 1,250 B/s は 1.3 KB/s（小数1桁でも 5 は切り上げ）", Monitor.speedText(1250), "1.3 KB/s")
        check("[6] 9,949 B/s は 9.9 KB/s（9.95 の直前）", Monitor.speedText(9949), "9.9 KB/s")
        check("[6] 9,950 B/s は 10 KB/s（10.0 と書かない）", Monitor.speedText(9950), "10 KB/s")
        check("[6] 10,000 B/s は 10 KB/s", Monitor.speedText(10000), "10 KB/s")
        check("[6] 12,000 B/s は 12 KB/s", Monitor.speedText(12000), "12 KB/s")
        check("[6] 12,499 B/s は 12 KB/s", Monitor.speedText(12499), "12 KB/s")
        check("[6] 12,500 B/s は 13 KB/s（四捨五入で 0.5 は切り上げ）", Monitor.speedText(12500), "13 KB/s")
        check("[6] 850,000 B/s は 850 KB/s", Monitor.speedText(850_000), "850 KB/s")
        check("[6] 999,499 B/s は 999 KB/s（999.5 の直前）", Monitor.speedText(999_499), "999 KB/s")
        check("[6] 999,500 B/s は 1.0 MB/s（四捨五入で 1000 になるので上げる）", Monitor.speedText(999_500), "1.0 MB/s")
        check("[6] 1,200,000 B/s は 1.2 MB/s", Monitor.speedText(1_200_000), "1.2 MB/s")
        check("[6] 9,949,999 B/s は 9.9 MB/s（MB/s でも 9.95 の直前）", Monitor.speedText(9_949_999), "9.9 MB/s")
        check("[6] 9,950,000 B/s は 10 MB/s", Monitor.speedText(9_950_000), "10 MB/s")
        check("[6] 12,000,000 B/s は 12 MB/s", Monitor.speedText(12_000_000), "12 MB/s")
        check("[6] 999,499,999 B/s は 999 MB/s", Monitor.speedText(999_499_999), "999 MB/s")
        check("[6] 999,500,000 B/s は 1.0 GB/s", Monitor.speedText(999_500_000), "1.0 GB/s")
        check("[6] 999,499,999,999 B/s は 999 GB/s", Monitor.speedText(999_499_999_999), "999 GB/s")
        check("[6] 999,500,000,000 B/s は 1.0 TB/s", Monitor.speedText(999_500_000_000), "1.0 TB/s")
        check("[6] 999,499,999,999,999 B/s は 999 TB/s", Monitor.speedText(999_499_999_999_999), "999 TB/s")
        check("[6] TB/s より上は無いので 999.5 TB/s は 1000 TB/s", Monitor.speedText(999.5e12), "1000 TB/s")
        check("[6] 1.5 × 10^15 B/s は 1500 TB/s", Monitor.speedText(1.5e15), "1500 TB/s")
        check("[6] 負の値は 0 として扱う（-1）", Monitor.speedText(-1), "0 KB/s")
        check("[6] 負の値は 0 として扱う（-500、そのままなら -0.5）", Monitor.speedText(-500), "0 KB/s")
        check("[6] 負の値は 0 として扱う（-2,000,000）", Monitor.speedText(-2_000_000), "0 KB/s")
        check("[6] -0.0 も 0 KB/s", Monitor.speedText(-0.0), "0 KB/s")

        let speedUnits = ["KB/s", "MB/s", "GB/s", "TB/s"]
        let speedScales = [1e3, 1e6, 1e9, 1e12]
        let speedValues = formatSamples(scales: speedScales, limit: 999.5e12, seed: 6)
        checkFormatProperties("[6]", units: speedUnits, scales: speedScales, values: speedValues, format: Monitor.speedText)
        check(
            "[6] 多くの負の値で、どれも 0 KB/s",
            speedValues.filter { $0 > 0 }.first { Monitor.speedText(-$0) != "0 KB/s" }.map { "-\($0) → \"\(Monitor.speedText(-$0))\"" } ?? "なし",
            "なし"
        )

        // MARK: [7] 割合の書き方

        check("[7] 0.12 は 12%", Monitor.percentText(0.12), "12%")
        check("[7] 0.124 は 12%", Monitor.percentText(0.124), "12%")
        check("[7] 0.125 は 13%（0.5 は切り上げ）", Monitor.percentText(0.125), "13%")
        check("[7] 0.625 は 63%（0.5 は切り上げ、偶数に寄せない）", Monitor.percentText(0.625), "63%")
        check("[7] 0.5 は 50%", Monitor.percentText(0.5), "50%")
        check("[7] 0 は 0%", Monitor.percentText(0), "0%")
        check("[7] 0.004 は 0%", Monitor.percentText(0.004), "0%")
        check("[7] 0.005 は 1%（0.5 は切り上げ）", Monitor.percentText(0.005), "1%")
        check("[7] 0 の直前（-0.001）は 0%", Monitor.percentText(-0.001), "0%")
        check("[7] -0.004 は 0%（-0% と書かない）", Monitor.percentText(-0.004), "0%")
        check("[7] -0.3 は 0%", Monitor.percentText(-0.3), "0%")
        check("[7] 0.994 は 99%", Monitor.percentText(0.994), "99%")
        check("[7] 0.996 は 100%", Monitor.percentText(0.996), "100%")
        check("[7] 1 は 100%", Monitor.percentText(1), "100%")
        check("[7] 1 の直後は 100%", Monitor.percentText(1.0.nextUp), "100%")
        check("[7] 1.5 は 100%", Monitor.percentText(1.5), "100%")
        do {
            var badShape: String?
            var badError: String?
            var badOrder: String?
            var previous: (x: Double, text: String, n: Int)?
            for i in -5000...15000 {
                let x = Double(i) / 10000  // -0.5 から 1.5 まで 0.0001 刻み
                let text = Monitor.percentText(x)
                let example = "\(x) → \"\(text)\""
                guard text.hasSuffix("%"), let n = Int(text.dropLast()), text.dropLast().allSatisfy({ ("0"..."9").contains($0) }),
                      (0...100).contains(n)
                else {
                    badShape = badShape ?? example
                    continue
                }
                if abs(Double(n) - min(max(x, 0), 1) * 100) > 0.5 + 1e-9 { badError = badError ?? example }
                if let p = previous, n < p.n { badOrder = badOrder ?? "\(p.x) → \"\(p.text)\" の次に \(example)" }
                previous = (x, text, n)
            }
            check("[7] -0.5〜1.5 のどれも「0〜100 の整数%」", badShape ?? "なし", "なし")
            check("[7] -0.5〜1.5 のどれも、0〜1 に寄せた値の 100 倍から 0.5 以内", badError ?? "なし", "なし")
            check("[7] -0.5〜1.5 で、大きい割合ほど小さく書かない", badOrder ?? "なし", "なし")
        }

        // MARK: [8] バイト数の書き方

        check("[8] 0 バイトは 0 MB", Monitor.sizeText(0), "0 MB")
        check("[8] 30,000 バイトは 0 MB（いちばん小さい単位は MB）", Monitor.sizeText(30_000), "0 MB")
        check("[8] 49,999 バイトは 0 MB（0.05 の直前）", Monitor.sizeText(49_999), "0 MB")
        check("[8] 50,000 バイトは 0.1 MB（0.05 の境目）", Monitor.sizeText(50_000), "0.1 MB")
        check("[8] 500,000 バイトは 0.5 MB", Monitor.sizeText(500_000), "0.5 MB")
        check("[8] 1,000,000 バイトは 1.0 MB", Monitor.sizeText(1_000_000), "1.0 MB")
        check("[8] 9,949,999 バイトは 9.9 MB（9.95 の直前）", Monitor.sizeText(9_949_999), "9.9 MB")
        check("[8] 9,950,000 バイトは 10 MB", Monitor.sizeText(9_950_000), "10 MB")
        check("[8] 12,500,000 バイトは 13 MB（0.5 は切り上げ）", Monitor.sizeText(12_500_000), "13 MB")
        check("[8] 999,499,999 バイトは 999 MB（999.5 の直前）", Monitor.sizeText(999_499_999), "999 MB")
        check("[8] 999,500,000 バイトは 1.0 GB", Monitor.sizeText(999_500_000), "1.0 GB")
        check("[8] 1,234,567,890 バイトは 1.2 GB", Monitor.sizeText(1_234_567_890), "1.2 GB")
        check("[8] 500,000,000,000 バイトは 500 GB", Monitor.sizeText(500_000_000_000), "500 GB")
        check("[8] 999.5 GB は 1.0 TB", Monitor.sizeText(999.5e9), "1.0 TB")
        check("[8] 999.4999… TB は 999 TB", Monitor.sizeText(999_499_999_999_999), "999 TB")
        check("[8] 999.5 TB は 1.0 PB", Monitor.sizeText(999.5e12), "1.0 PB")
        check("[8] PB より上は無いので 999.5 PB は 1000 PB", Monitor.sizeText(999.5e15), "1000 PB")
        check("[8] 1.5 × 10^18 バイトは 1500 PB", Monitor.sizeText(1.5e18), "1500 PB")
        check("[8] 負の値は 0 として扱う（-1）", Monitor.sizeText(-1), "0 MB")
        check("[8] 負の値は 0 として扱う（-500,000、そのままなら -0.5）", Monitor.sizeText(-500_000), "0 MB")
        check("[8] 負の値は 0 として扱う（-5 × 10^9）", Monitor.sizeText(-5e9), "0 MB")

        // ここが設計の判断。メモリは macOS が 1024 ごとで数えるので、積んでいる量（36 GB）と揃う。
        // ディスクは Finder と同じ 1000 ごと。
        check("[8] 36 GiB は base 1024 で 36 GB", Monitor.sizeText(38_654_705_664, base: 1024), "36 GB")
        check("[8] 36 GiB は base 1000 で 39 GB", Monitor.sizeText(38_654_705_664, base: 1000), "39 GB")
        check("[8] base の既定は 1000", Monitor.sizeText(38_654_705_664), "39 GB")
        check("[8] base 1024 で 1 MiB は 1.0 MB", Monitor.sizeText(1_048_576, base: 1024), "1.0 MB")
        check("[8] base 1024 で 512 KiB は 0.5 MB", Monitor.sizeText(524_288, base: 1024), "0.5 MB")
        check("[8] base 1024 で 0.05 MiB の直前（52,428）は 0 MB", Monitor.sizeText(52_428, base: 1024), "0 MB")
        check("[8] base 1024 で 0.05 MiB の直後（52,429）は 0.1 MB", Monitor.sizeText(52_429, base: 1024), "0.1 MB")
        check("[8] base 1024 で 9.95 MiB の直前（10,433,331）は 9.9 MB", Monitor.sizeText(10_433_331, base: 1024), "9.9 MB")
        check("[8] base 1024 で 9.95 MiB の直後（10,433,332）は 10 MB", Monitor.sizeText(10_433_332, base: 1024), "10 MB")
        check("[8] base 1024 で 999.5 MiB の直前は 999 MB", Monitor.sizeText(1_048_051_711, base: 1024), "999 MB")
        check("[8] base 1024 で 999.5 MiB は 1.0 GB", Monitor.sizeText(1_048_051_712, base: 1024), "1.0 GB")
        check("[8] base 1024 で 16 GiB は 16 GB", Monitor.sizeText(17_179_869_184, base: 1024), "16 GB")
        check("[8] base 1024 でも PB より上は無い（999.5 PiB は 1000 PB）", Monitor.sizeText(999.5 * pow(1024, 5), base: 1024), "1000 PB")
        check("[8] base 1024 でも負の値は 0 MB", Monitor.sizeText(-1, base: 1024), "0 MB")

        let sizeUnits = ["MB", "GB", "TB", "PB"]
        for base in [1000.0, 1024.0] {
            let scales = (2...5).map { pow(base, Double($0)) }
            let values = formatSamples(scales: scales, limit: 999.5 * scales[3], seed: 8)
            checkFormatProperties("[8] base \(Int(base))", units: sizeUnits, scales: scales, values: values) {
                Monitor.sizeText($0, base: base)
            }
            check(
                "[8] base \(Int(base)) 多くの負の値で、どれも 0 MB",
                values.filter { $0 > 0 }.first { Monitor.sizeText(-$0, base: base) != "0 MB" }.map { "-\($0)" } ?? "なし",
                "なし"
            )
            if base == 1000 {
                check(
                    "[8] 多くの値で、base を渡さないときは base 1000 と同じ",
                    values.first { Monitor.sizeText($0) != Monitor.sizeText($0, base: 1000) }.map { "\($0)" } ?? "なし",
                    "なし"
                )
            }
        }

        // MARK: [9] 上下2段の列に詰める

        check("[9] 空の入力は空の出力", Monitor.columns([]), [])
        check("[9] 1行なら1列に1行", columnTexts([.cpu]), [["cpu"]])
        check("[9] ほかの行は2つずつ詰める", columnTexts([.cpu, .memory]), [["cpu", "memory"]])
        check("[9] 1つ余ったら、その列は1行だけ", columnTexts([.cpu, .memory, .disk]), [["cpu", "memory"], ["disk"]])
        check("[9] 下りのすぐ後に上りなら、その2つで1列（上が down、下が up）", columnTexts([.down, .up]), [["down", "up"]])
        check("[9] 組の後のほかの行は、また2つずつ", columnTexts([.down, .up, .cpu, .memory]), [["down", "up"], ["cpu", "memory"]])
        check("[9] 組の後に1行だけなら、1行の列", columnTexts([.down, .up, .cpu]), [["down", "up"], ["cpu"]])
        // ここが設計の判断。下りと上りで1つの項目なので、ほかの行と混ぜない。
        check("[9] 組の前の詰めかけの1行は、1行の列として先に閉じる", columnTexts([.cpu, .down, .up]), [["cpu"], ["down", "up"]])
        check("[9] 組の前が2行で埋まっていれば、そのまま", columnTexts([.cpu, .memory, .down, .up]), [["cpu", "memory"], ["down", "up"]])
        check(
            "[9] 組を挟んで、前も後も詰める",
            columnTexts([.cpu, .down, .up, .memory, .disk]),
            [["cpu"], ["down", "up"], ["memory", "disk"]]
        )
        check("[9] 組を挟んで、前も後も1行", columnTexts([.cpu, .down, .up, .memory]), [["cpu"], ["down", "up"], ["memory"]])
        check("[9] up が続かない down は、ふつうの行（後ろと詰める）", columnTexts([.down, .cpu]), [["down", "cpu"]])
        check("[9] up が続かない down は、ふつうの行（前と詰める）", columnTexts([.cpu, .down]), [["cpu", "down"]])
        check("[9] down だけなら1行の列", columnTexts([.down]), [["down"]])
        check("[9] 間に別の行がある down と up は、どちらもふつうの行", columnTexts([.cpu, .down, .memory, .up]), [["cpu", "down"], ["memory", "up"]])
        check("[9] 並びが逆（up、down）なら組ではない", columnTexts([.up, .down]), [["up", "down"]])
        check("[9] down が2つ続いたら、組になるのは up の直前の down", columnTexts([.down, .down, .up]), [["down"], ["down", "up"]])
        check("[9] 組が2つ続けば2列", columnTexts([.down, .up, .down, .up]), [["down", "up"], ["down", "up"]])

        // 5 種類の行を 0〜6 行並べた全部の並びで、決めごとから出る性質を見る。
        // この4つが揃うと答えは1通りに決まる（ほかの行の区切りは 2, 2, …, 最後だけ 1 か 2）。
        do {
            let kinds: [Kind] = [.down, .up, .cpu, .memory, .disk]
            var inputs: [[Kind]] = [[]]
            var frontier: [[Kind]] = [[]]
            for _ in 1...6 {
                frontier = frontier.flatMap { seq in kinds.map { seq + [$0] } }
                inputs += frontier
            }
            var badFlat: String?
            var badSize: String?
            var badPair: String?
            var badSingle: String?
            for input in inputs {
                // 同じ種類が並んでも区別できるように、text は元の位置にする。
                let rows = input.enumerated().map { Line(kind: $1, text: "\($0)") }
                let result = Monitor.columns(rows)
                let example = "\(input.map { "\($0)" }) → \(result.map { $0.map(\.text) })"
                if result.flatMap({ $0 }) != rows { badFlat = badFlat ?? example }
                if !result.allSatisfy({ (1...2).contains($0.count) }) { badSize = badSize ?? example }
                for i in rows.indices.dropLast() where input[i] == .down && input[i + 1] == .up {
                    if !result.contains([rows[i], rows[i + 1]]) { badPair = badPair ?? example }
                }
                for (j, column) in result.enumerated() where column.count == 1 {
                    let last = j == result.count - 1
                    let beforePair = !last && result[j + 1].map(\.kind) == [.down, .up]
                    if !last && !beforePair { badSingle = badSingle ?? example }
                }
            }
            check("[9] 全部の並び（\(inputs.count) 通り）で、列を順に平らにすると元の並び", badFlat ?? "なし", "なし")
            check("[9] 全部の並びで、どの列も1行か2行", badSize ?? "なし", "なし")
            check("[9] 全部の並びで、down のすぐ後の up は、その2つだけで1列", badPair ?? "なし", "なし")
            check("[9] 全部の並びで、1行の列は最後か、down/up の組の直前にだけある", badSingle ?? "なし", "なし")
        }

        // MARK: 32 ビットを越える大きさ（[2][4]）

        // 差の合計は 32 ビットに収まらないことがある。実装が UInt32 のまま足していると
        // ここで溢れてプロセスごと止まるので、ほかの結果が見えるように最後に置く。
        check(
            "[2] 差の合計が 32 ビットを超えても割合を出せる（全部 0 から全部最大）",
            Monitor.cpuUsage(from: zero, to: maxed),
            0.75
        )
        do {
            var random = MonitorTestRandom(seed: 4)
            var badRange: String?
            var badNil: String?
            for _ in 0..<100_000 {
                let old = Ticks(user: random.u32(), system: random.u32(), idle: random.u32(), nice: random.u32())
                // 各フィールドは半々で、そのまま（差 0）か、でたらめな値。全部そのままになる組も混ざる。
                let keep = { (v: UInt32) -> UInt32 in random.below(2) == 0 ? v : random.u32() }
                let new = Ticks(user: keep(old.user), system: keep(old.system), idle: keep(old.idle), nice: keep(old.nice))
                let r = Monitor.cpuUsage(from: old, to: new)
                if (r == nil) != (old == new) { badNil = badNil ?? "\(old) → \(new): \(String(describing: r))" }
                if let r, !(0...1).contains(r) { badRange = badRange ?? "\(old) → \(new): \(r)" }
            }
            check("[2] どんな2つの値でも、忙しさは 0〜1 に収まる", badRange ?? "なし", "なし")
            check("[4] どんな2つの値でも、nil になるのは差がすべて 0 のときだけ", badNil ?? "なし", "なし")
        }

        print(failures == 0 ? "\nすべて通った" : "\n\(failures) 件失敗")
        exit(failures == 0 ? 0 : 1)
    }
}
