import Foundation

// Claude Code と Codex の使用量の枠の読み方と書き方（UsageLimits）を、決めごとから確かめる。
//
// 実装は見ずに、決めごと（仕様）の一文ずつをケースにしてある。テスト名の先頭の [n] は決めごとの番号。
// 今の実装の写しではなく、仕様を固定するためのテスト。落ちたら期待値ではなく実装を疑う。
// 値で固定する例に加えて、たくさんの入力で成り立つはずの性質も見る。
// 仕様から一通りに読めなかったところは、いちばん自然な読みで書き、テスト名に「（要確認）」と付けた。
// 番号に b の付いたもの（[1b] [5b] [11b] [15b]）は、書いてもらったあとで改めた・足した決めごと。
//
// CLI が出す1行は文字列で渡すので、claude も codex も、ネットも要らない。
// この Mac の地域・時間帯・現在時刻にも依らない。暦はグレゴリオ暦に時間帯を明示して作り、
// 日付は暦と DateComponents か unix 秒から作る（Date() も Locale.current も使わない）。
// さらに、この Mac の時間帯が実装に漏れていたら見えるように、プロセスの既定の時間帯を
// どの Mac でもまず使わない +14 時間（Pacific/Kiritimati）にしてから走らせる。
//
// 決めごと（テスト名の先頭の [n] がこの番号）
//  1. claude(line) は usage_report オブジェクトを持つ JSON オブジェクトの行でなければ nil。
// 1b. ただし usage_report の来ないまま type が result の行が来たら noPlan。
//  2. 行は kind だけで分ける。session → session「5時間」、weekly_all → week「週」。
//  3. ほかの kind は others に、サーバの順で。名前は「<label> の<group 名>」。
//  4. 2つ目の session / weekly_all は others へ（3 の名前で）。最初のものが枠に残る。
//  5. percent はそのまま。resets_at は Date に。null・無い・読めない → nil（枠そのものは残る）。
// 5b. kind か percent が読めない行は、その行だけ捨てる。ほかの欄は、形が違えばその欄だけ無いものとして読む。
//  6. rate_limits: null → noPlan、limits: null → unreadable、limits: [] → 空の Usage。
//  7. date(iso:) は 5 に従う。
//  8. codex(line) は rateLimits の要求と同じ id の返事でなければ nil。
//  9. codexRequests は initialize・initialized・account/rateLimits/read の3行。
// 10. error 付き、または result.rateLimits の無い返事 → unreadable。
// 11. primary → secondary の順に、windowDurationMins で分ける。両方 null → noPlan。
// 11b. rateLimitsByLimitId のほかの枠は others に「<limitName か limitId> の<spanName>」で、limitId の順。
// 12. spanName(minutes:) の書き方。
// 13. barText の書き方。
// 14. detailText の書き方。
// 15. resetText の書き方。暦の時間帯で同じ日かどうか。
// 15b. いちばん近い分に丸め、丸めたあとの時刻で同じ日かどうかを決める。
// 16. Monitor.columns で claude のすぐ後の codex は1列。
// 17. Monitor.Item の既定と asksCommand。

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

private typealias Window = UsageLimits.Window
private typealias Usage = UsageLimits.Usage
private typealias State = UsageLimits.State
private typealias Line = Monitor.Line
private typealias Kind = Monitor.Line.Kind

// 性質を見るための乱数。種を固定して、毎回同じ入力で試す（splitmix64）。
private struct UsageTestRandom: RandomNumberGenerator {
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
    /// 0 以上 n 未満
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[below(xs.count)] }
    mutating func chance() -> Bool { below(2) == 0 }
}

// MARK: - 暦と日付

/// この Mac の設定に依らない暦。
private func makeCalendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    c.locale = Locale(identifier: "ja_JP")
    return c
}

private let tokyo = makeCalendar("Asia/Tokyo")
private let utc = makeCalendar("UTC")

/// 暦の時間帯での、その年月日・時刻の瞬間。
private func at(_ c: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// 小数秒のある日付は、1ms 未満の誤差まで同じとみなす（小数秒を何桁まで持つかは決めごとに無い）。
/// 期待の側は「≈unix 秒」、合っていれば実際も同じ文字列になる。
private func near(_ actual: Date?, _ expected: Date) -> String {
    let e = String(format: "≈%.6f", expected.timeIntervalSince1970)
    guard let actual else { return "nil" }
    return abs(actual.timeIntervalSince(expected)) < 0.001 ? e : String(format: "%.6f", actual.timeIntervalSince1970)
}

// MARK: - 結果を読める形にする

/// 枠を「名前|percent|resetsAt の unix 秒（小数 digits 桁まで）」で。小数秒の桁の違いに左右されずに比べるため。
private func describe(_ w: Window?, digits: Int = 3) -> String {
    guard let w else { return "なし" }
    let reset = w.resetsAt.map { String(format: "%.\(digits)f", $0.timeIntervalSince1970) } ?? "nil"
    return "\(w.name)|\(w.percent)|\(reset)"
}

private func describe(_ s: State?, digits: Int = 3) -> String {
    switch s {
    case nil: return "nil"
    case .failed(let f)?: return "failed(\(f))"
    case .read(let u)?:
        let others = u.others.map { describe($0, digits: digits) }.joined(separator: ", ")
        return "read(session=\(describe(u.session, digits: digits)) week=\(describe(u.week, digits: digits)) others=[\(others)])"
    }
}

private func W(_ name: String, _ percent: Double, _ resetsAt: Date? = nil) -> Window {
    Window(name: name, percent: percent, resetsAt: resetsAt)
}

private func read(session: Window? = nil, week: Window? = nil, others: [Window] = []) -> State {
    .read(Usage(session: session, week: week, others: others))
}

// MARK: - Claude Code の1行を作る

/// 文字列を JSON の文字列に（テストで使う文字列は、エスケープの要る文字を含まない）。
private func q(_ s: String) -> String { "\"\(s)\"" }

private func named(_ s: String) -> String { #"{"display_name":"\#(s)"}"# }

/// scope。model・surface は nil なら null。
private func scope(model: String? = nil, surface: String? = nil) -> String {
    #"{"model":\#(model.map(named) ?? "null"),"surface":\#(surface.map(named) ?? "null")}"#
}

/// rate_limits.limits の1行。値は JSON のまま渡す。nil のキーは書かない（kind は文字列で渡す）。
private func row(
    _ kind: String,
    group: String?,
    percent: String = "0",
    resetsAt: String? = "null",
    scope: String? = "null",
    severity: String = q("normal"),
    isActive: String = "false"
) -> String {
    var fields = ["\"kind\":\(q(kind))"]
    if let group { fields.append("\"group\":\(group)") }
    fields.append("\"percent\":\(percent)")
    if let resetsAt { fields.append("\"resets_at\":\(resetsAt)") }
    if let scope { fields.append("\"scope\":\(scope)") }
    fields.append("\"severity\":\(severity)")
    fields.append("\"is_active\":\(isActive)")
    return "{\(fields.joined(separator: ","))}"
}

/// usage_report を持つ stream-json の1行。rateLimits は JSON のまま（nil ならキーを書かない）。
private func report(rateLimits: String?) -> String {
    let rl = rateLimits.map { #","rate_limits":\#($0)"# } ?? ""
    return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Current session: 3% used"}]},"usage_report":{"session":{"total_cost_usd":0}\#(rl)}}"#
}

/// limits にこの行を並べた1行。
private func limitsLine(_ rows: [String]) -> String {
    report(rateLimits: #"{"limits":[\#(rows.joined(separator: ","))],"extra_usage":{"is_enabled":false}}"#)
}

/// 決めごとに付いていた実際の1行（ほかのフィールドは削ってある）。
private let claudeExample = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Current session: 3% used"}]},"usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":3,"resets_at":"2026-10-28T10:20:00.364309+00:00","scope":null,"severity":"normal","is_active":false},{"kind":"weekly_all","group":"weekly","percent":14,"resets_at":"2026-11-03T22:00:00.364333+00:00","scope":null,"severity":"normal","is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-11-03T22:00:00+00:00","scope":{"model":{"display_name":"Fable"},"surface":null},"severity":"normal","is_active":false}],"extra_usage":{"is_enabled":false}}}}"#

// MARK: - Codex の1行を作る

/// codexRequests の各行（最後の改行の後ろの空も含む）。
private let requestParts = UsageLimits.codexRequests.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// JSON の値を JSON の文字列に戻す（id を返事に埋め込むため）。
private func jsonText(_ value: Any?) -> String? {
    guard let value, !(value is NSNull),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    else { return nil }
    return String(data: data, encoding: .utf8)
}

private func requestID(method: String) -> String? {
    requestParts.compactMap(jsonObject).first { $0["method"] as? String == method }.flatMap { jsonText($0["id"]) }
}

/// account/rateLimits/read の要求の id を JSON のまま。決め打ちせず codexRequests から取る。
/// 取れなければ null にしておく（9 のテストが落ち、返事のテストも nil になって落ちる）。
private let rateLimitsID = requestID(method: "account/rateLimits/read") ?? "null"
private let initializeID = requestID(method: "initialize") ?? "null"

/// 枠1つ。nil のキーは書かない。
private func codexWindow(_ used: Int, mins: String? = "null", resetsAt: String? = "null") -> String {
    var fields = ["\"usedPercent\":\(used)"]
    if let mins { fields.append("\"windowDurationMins\":\(mins)") }
    if let resetsAt { fields.append("\"resetsAt\":\(resetsAt)") }
    return "{\(fields.joined(separator: ","))}"
}

/// rateLimits の要求への返事。primary・secondary は JSON のまま。
private func codexReply(primary: String, secondary: String, id: String = rateLimitsID) -> String {
    #"{"id":\#(id),"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"primary":\#(primary),"secondary":\#(secondary),"credits":{"hasCredits":false},"planType":"plus"},"rateLimitsByLimitId":{}}}"#
}

/// 決めごとに付いていた実際の返事（id だけ codexRequests から取ったものにしてある）。
private let codexExample = codexReply(
    primary: codexWindow(0, mins: "300", resetsAt: "1793183187"),
    secondary: codexWindow(46, mins: "10080", resetsAt: "1793644644")
)

// MARK: - 列（16）

private func lines(_ kinds: [Kind]) -> [Line] {
    kinds.map { Line(kind: $0, text: "\($0)") }
}

/// 列を、各行の text で読む。
private func columnTexts(_ kinds: [Kind]) -> [[String]] {
    Monitor.columns(lines(kinds)).map { $0.map(\.text) }
}

// MARK: - spanName（12）を読み戻す

/// spanName の書いた名前を分に戻す。決めごとの形でなければ nil。
private func minutes(ofSpanName name: String) -> Int? {
    if name == "週" { return 10080 }
    for (suffix, unit) in [("時間", 60), ("週", 10080), ("日", 1440), ("分", 1)] where name.hasSuffix(suffix) {
        let digits = name.dropLast(suffix.count)
        guard !digits.isEmpty, digits.first != "0", digits.allSatisfy({ ("0"..."9").contains($0) }), let k = Int(digits)
        else { return nil }
        return k * unit
    }
    return nil
}

@main
struct UsageLimitsTests {
    static func main() {
        // 途中で止まっても、そこまでの結果が見えるように1行ずつ出す。
        setvbuf(stdout, nil, _IOLBF, 0)
        // この Mac の時間帯が漏れたら見えるように（DateFormatter や暦の既定がこれになる）。
        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!

        let U = UsageLimits.self

        // MARK: [1] usage_report の無い行は nil

        check("[1] JSON でない文字列は nil", U.claude("Current session: 3% used"), nil)
        check("[1] 空の文字列は nil", U.claude(""), nil)
        check("[1] 途中で切れた JSON は nil", U.claude(#"{"type":"assistant","usage_report":{"rate_limits":"#), nil)
        check(
            "[1] stream-json の初めの system イベントは nil",
            U.claude(#"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"x","tools":[],"model":"m"}"#),
            nil
        )
        check(
            "[1] usage_report の無い assistant イベントは nil",
            U.claude(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Current session: 3% used"}]}}"#),
            nil
        )
        // 決めごとを改めた: 報告は新しい CLI で claude.ai のプランのときしか付かない（Claude Code の型の説明）。
        // 報告が来ないまま終わりの行が来たら、待ち続けて「読めなかった」にせず、プランの枠が出ないとする。
        check(
            "[1b] usage_report の来ないまま result の行が来たら noPlan",
            U.claude(#"{"type":"result","subtype":"success","is_error":false,"result":"Current session: 3% used","total_cost_usd":0}"#),
            .failed(.noPlan)
        )
        check(
            "[1b] result の行が失敗でも noPlan",
            U.claude(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#),
            .failed(.noPlan)
        )
        check(
            "[1b] result 以外の type なら nil（system の init など）",
            U.claude(#"{"type":"system","subtype":"init","apiKeySource":"none"}"#),
            nil
        )
        check(
            "[1] usage_report が上の階層でなく message の中にあるだけなら nil",
            U.claude(#"{"type":"assistant","message":{"usage_report":{"rate_limits":{"limits":[]}}}}"#),
            nil
        )
        check("[1] usage_report が null なら nil", U.claude(#"{"type":"assistant","usage_report":null}"#), nil)
        check("[1] usage_report が文字列なら nil", U.claude(#"{"type":"assistant","usage_report":"x"}"#), nil)
        check("[1] usage_report が配列なら nil", U.claude(#"{"type":"assistant","usage_report":[]}"#), nil)
        check(
            "[1] オブジェクトでなく配列の行は nil（中に usage_report があっても）",
            U.claude("[\(limitsLine([]))]"),
            nil
        )
        check("[1] usage_report を持つ行は nil でない", U.claude(claudeExample) == nil, false)

        // MARK: 決めごとに付いていた実際の1行（[2][3][5]）

        let exampleState = read(
            session: W("5時間", 3, at(utc, 2026, 10, 28, 10, 20).addingTimeInterval(0.364309)),
            week: W("週", 14, at(utc, 2026, 11, 3, 22, 0).addingTimeInterval(0.364333)),
            others: [W("Fable の週", 0, at(utc, 2026, 11, 3, 22, 0))]
        )
        // 分け方・名前・percent・resetsAt の秒までを見る。小数秒は下の [5] で別に見る。
        check(
            "[2][3][5] 実際の1行: 5時間 3%・週 14%・Fable の週 0%（resetsAt は秒まで）",
            describe(U.claude(claudeExample), digits: 0),
            describe(exampleState, digits: 0)
        )
        // 決めごとは「小数秒は何桁でもよい」とだけ言い、どこまで残すかは言っていない。ここではその瞬間（1ms 未満の誤差）とした。
        check(
            "[5] 実際の1行の resets_at の小数秒（.364309・.364333）も残す（要確認）",
            describe(U.claude(claudeExample)),
            describe(exampleState)
        )

        // MARK: [2] kind だけで分ける

        check(
            "[2] kind が session の行は session に「5時間」で",
            describe(U.claude(limitsLine([row("session", group: q("session"), percent: "7")]))),
            describe(read(session: W("5時間", 7)))
        )
        check(
            "[2] kind が weekly_all の行は week に「週」で",
            describe(U.claude(limitsLine([row("weekly_all", group: q("weekly"), percent: "21")]))),
            describe(read(week: W("週", 21)))
        )
        check(
            "[2] group が weekly でも kind が session なら session",
            describe(U.claude(limitsLine([row("session", group: q("weekly"), percent: "7")]))),
            describe(read(session: W("5時間", 7)))
        )
        check(
            "[2] group が session でも kind が weekly_all なら week",
            describe(U.claude(limitsLine([row("weekly_all", group: q("session"), percent: "21")]))),
            describe(read(week: W("週", 21)))
        )
        check(
            "[2] group が無くても kind が session なら session",
            describe(U.claude(limitsLine([row("session", group: nil, percent: "7")]))),
            describe(read(session: W("5時間", 7)))
        )
        check(
            "[2] session の行に scope の display_name があっても、名前は「5時間」",
            describe(U.claude(limitsLine([row("session", group: q("session"), percent: "7", scope: scope(model: "Fable"))]))),
            describe(read(session: W("5時間", 7)))
        )
        check(
            "[2] weekly_all の行に scope の display_name があっても、名前は「週」",
            describe(U.claude(limitsLine([row("weekly_all", group: q("weekly"), percent: "21", scope: scope(surface: "Web"))]))),
            describe(read(week: W("週", 21)))
        )
        check(
            "[2] is_active が false でも、severity が何でも枠に入る",
            describe(U.claude(limitsLine([
                row("session", group: q("session"), percent: "95", severity: q("critical"), isActive: "false"),
                row("weekly_all", group: q("weekly"), percent: "80", severity: q("warning"), isActive: "false"),
            ]))),
            describe(read(session: W("5時間", 95), week: W("週", 80)))
        )
        check(
            "[2] group が weekly でも kind が weekly_scoped なら week でなく others",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "5")]))),
            describe(read(others: [W("週", 5)]))
        )
        check(
            "[2] group が session でも kind が別なら session でなく others",
            describe(U.claude(limitsLine([row("session_scoped", group: q("session"), percent: "5")]))),
            describe(read(others: [W("5時間", 5)]))
        )
        check(
            "[2] display_name が「session」でも kind が別なら others",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "5", scope: scope(model: "session"))]))),
            describe(read(others: [W("session の週", 5)]))
        )
        check(
            "[2] kind の大文字小文字が違えば別の kind（Session は others）",
            describe(U.claude(limitsLine([row("Session", group: q("session"), percent: "5")]))),
            describe(read(others: [W("5時間", 5)]))
        )

        // MARK: [3] ほかの kind は others に、名前は「<label> の<group 名>」

        check(
            "[3] model の display_name があれば「<model> の週」",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: scope(model: "Fable"))]))),
            describe(read(others: [W("Fable の週", 1)]))
        )
        check(
            "[3] model が無く surface の display_name があれば「<surface> の週」",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: scope(surface: "Web"))]))),
            describe(read(others: [W("Web の週", 1)]))
        )
        check(
            "[3] model と surface の両方があれば model",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: scope(model: "Fable", surface: "Web"))]))),
            describe(read(others: [W("Fable の週", 1)]))
        )
        check(
            "[3] model に display_name が無ければ surface（要確認）",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: #"{"model":{},"surface":{"display_name":"Web"}}"#)]))),
            describe(read(others: [W("Web の週", 1)]))
        )
        check(
            "[3] model の display_name が null なら surface（要確認）",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: #"{"model":{"display_name":null},"surface":{"display_name":"Web"}}"#)]))),
            describe(read(others: [W("Web の週", 1)]))
        )
        check(
            "[3] group が session なら「<label> の5時間」",
            describe(U.claude(limitsLine([row("session_scoped", group: q("session"), percent: "1", scope: scope(model: "Fable"))]))),
            describe(read(others: [W("Fable の5時間", 1)]))
        )
        check(
            "[3] group がほかの文字列なら、そのまま（「<label> のmonthly」）",
            describe(U.claude(limitsLine([row("monthly_scoped", group: q("monthly"), percent: "1", scope: scope(model: "Fable"))]))),
            describe(read(others: [W("Fable のmonthly", 1)]))
        )
        check(
            "[3] group の大文字小文字が違えば読み替えない（Weekly はそのまま）",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("Weekly"), percent: "1")]))),
            describe(read(others: [W("Weekly", 1)]))
        )
        check(
            "[3] scope が null なら group 名だけ（「週」）",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: "null")]))),
            describe(read(others: [W("週", 1)]))
        )
        check(
            "[3] scope が無ければ group 名だけ（「週」）",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: nil)]))),
            describe(read(others: [W("週", 1)]))
        )
        check(
            "[3] scope の model・surface が両方 null なら group 名だけ",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: scope())]))),
            describe(read(others: [W("週", 1)]))
        )
        check(
            "[3] scope が空のオブジェクトなら group 名だけ",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: "{}")]))),
            describe(read(others: [W("週", 1)]))
        )
        check(
            "[3] label が無く group がほかの文字列なら、その文字列だけ",
            describe(U.claude(limitsLine([row("monthly_all", group: q("monthly"), percent: "1")]))),
            describe(read(others: [W("monthly", 1)]))
        )
        check(
            "[3] group が無ければ kind をそのまま group 名に（「Fable のmonthly_all」）",
            describe(U.claude(limitsLine([row("monthly_all", group: nil, percent: "1", scope: scope(model: "Fable"))]))),
            describe(read(others: [W("Fable のmonthly_all", 1)]))
        )
        check(
            "[3] group も label も無ければ kind だけ",
            describe(U.claude(limitsLine([row("monthly_all", group: nil, percent: "1")]))),
            describe(read(others: [W("monthly_all", 1)]))
        )
        check(
            "[3] group が null なら、無いときと同じく kind をそのまま",
            describe(U.claude(limitsLine([row("monthly_all", group: "null", percent: "1")]))),
            describe(read(others: [W("monthly_all", 1)]))
        )
        check(
            "[3] display_name が空の文字列なら label 無しとみなす（「週」）（要確認）",
            describe(U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "1", scope: scope(model: ""))]))),
            describe(read(others: [W("週", 1)]))
        )
        check(
            "[3] others はサーバの順のまま（session・week の行を間に挟んでも）",
            describe(U.claude(limitsLine([
                row("weekly_scoped", group: q("weekly"), percent: "1", scope: scope(model: "Opus")),
                row("session", group: q("session"), percent: "2"),
                row("monthly_all", group: q("monthly"), percent: "3"),
                row("weekly_all", group: q("weekly"), percent: "4"),
                row("weekly_scoped", group: q("weekly"), percent: "5", scope: scope(model: "Fable")),
                row("session_scoped", group: q("session"), percent: "6", scope: scope(surface: "Web")),
            ]))),
            describe(read(
                session: W("5時間", 2),
                week: W("週", 4),
                others: [W("Opus の週", 1), W("monthly", 3), W("Fable の週", 5), W("Web の5時間", 6)]
            ))
        )

        // MARK: [4] 2つ目の session / weekly_all

        check(
            "[4] 2つ目の session は others に、最初のものが session に残る",
            describe(U.claude(limitsLine([
                row("session", group: q("session"), percent: "10"),
                row("session", group: q("session"), percent: "90", scope: scope(model: "Fable")),
            ]))),
            describe(read(session: W("5時間", 10), others: [W("Fable の5時間", 90)]))
        )
        check(
            "[4] 2つ目の session に label が無ければ others の名前は「5時間」",
            describe(U.claude(limitsLine([
                row("session", group: q("session"), percent: "10"),
                row("session", group: q("session"), percent: "90"),
            ]))),
            describe(read(session: W("5時間", 10), others: [W("5時間", 90)]))
        )
        check(
            "[4] 2つ目の weekly_all は others に、最初のものが week に残る",
            describe(U.claude(limitsLine([
                row("weekly_all", group: q("weekly"), percent: "10", isActive: "false"),
                row("weekly_all", group: q("weekly"), percent: "90", scope: scope(surface: "Web"), isActive: "true"),
            ]))),
            describe(read(week: W("週", 10), others: [W("Web の週", 90)]))
        )
        check(
            "[4] 3つ目も others に、順のまま",
            describe(U.claude(limitsLine([
                row("weekly_all", group: q("weekly"), percent: "10"),
                row("weekly_all", group: q("weekly"), percent: "20", scope: scope(model: "A")),
                row("weekly_scoped", group: q("weekly"), percent: "30", scope: scope(model: "B")),
                row("weekly_all", group: q("weekly"), percent: "40", scope: scope(model: "C")),
            ]))),
            describe(read(week: W("週", 10), others: [W("A の週", 20), W("B の週", 30), W("C の週", 40)]))
        )
        check(
            "[4] 2つ目の session の group が weekly なら others の名前は「週」（名前は 3 に従う）",
            describe(U.claude(limitsLine([
                row("session", group: q("session"), percent: "10"),
                row("session", group: q("weekly"), percent: "20", scope: scope(model: "Fable")),
            ]))),
            describe(read(session: W("5時間", 10), others: [W("Fable の週", 20)]))
        )
        check(
            "[4] 2つ目の session に group が無ければ kind の「session」がそのまま名前に（要確認）",
            describe(U.claude(limitsLine([
                row("session", group: q("session"), percent: "10"),
                row("session", group: nil, percent: "20"),
            ]))),
            describe(read(session: W("5時間", 10), others: [W("session", 20)]))
        )

        // MARK: [5] percent と resets_at

        check(
            "[5] percent は小数もそのまま（12.5）",
            describe(U.claude(limitsLine([row("session", group: q("session"), percent: "12.5")]))),
            describe(read(session: W("5時間", 12.5)))
        )
        check(
            "[5] percent は 0〜100 のまま（割合に直さない、100 は 100）",
            describe(U.claude(limitsLine([row("session", group: q("session"), percent: "100"), row("weekly_all", group: q("weekly"), percent: "0.25")]))),
            describe(read(session: W("5時間", 100), week: W("週", 0.25)))
        )
        check(
            "[5] percent が 100 を超えていても丸めずそのまま",
            describe(U.claude(limitsLine([row("session", group: q("session"), percent: "130")]))),
            describe(read(session: W("5時間", 130)))
        )
        let wholeReset = at(utc, 2026, 11, 3, 22, 0)
        check(
            "[5] resets_at は Date に（小数秒の無い +00:00、枠はそのまま比べる）",
            U.claude(limitsLine([row("weekly_all", group: q("weekly"), percent: "14", resetsAt: q("2026-11-03T22:00:00+00:00"))])),
            read(week: W("週", 14, wholeReset))
        )
        check(
            "[5] resets_at が Z で終わっても Date に",
            U.claude(limitsLine([row("weekly_all", group: q("weekly"), percent: "14", resetsAt: q("2026-11-03T22:00:00Z"))])),
            read(week: W("週", 14, wholeReset))
        )
        check(
            "[5] resets_at の小数秒が1桁でも Date に、小数秒も残す（要確認）",
            describe(U.claude(limitsLine([row("weekly_all", group: q("weekly"), percent: "14", resetsAt: q("2026-11-03T22:00:00.5+00:00"))]))),
            describe(read(week: W("週", 14, wholeReset.addingTimeInterval(0.5))))
        )
        check(
            "[5] resets_at が null なら resetsAt は nil、枠は残る",
            U.claude(limitsLine([row("session", group: q("session"), percent: "3", resetsAt: "null")])),
            read(session: W("5時間", 3, nil))
        )
        check(
            "[5] resets_at が無ければ resetsAt は nil、枠は残る",
            U.claude(limitsLine([row("session", group: q("session"), percent: "3", resetsAt: nil)])),
            read(session: W("5時間", 3, nil))
        )
        check(
            "[5] resets_at が読めない文字列なら resetsAt は nil、枠は残る",
            U.claude(limitsLine([row("session", group: q("session"), percent: "3", resetsAt: q("tomorrow"))])),
            read(session: W("5時間", 3, nil))
        )
        check(
            "[5] resets_at が空の文字列なら resetsAt は nil、枠は残る",
            U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "3", resetsAt: q(""), scope: scope(model: "Fable"))])),
            read(others: [W("Fable の週", 3, nil)])
        )
        check(
            "[5] resets_at が数（unix 秒）なら ISO 8601 でないので nil、枠は残る（要確認）",
            U.claude(limitsLine([row("session", group: q("session"), percent: "3", resetsAt: "1793182800")])),
            read(session: W("5時間", 3, nil))
        )

        // MARK: [5b] 読めない行
        //
        // 決めごとを足した: 種類（kind）か割合（percent）が読めない行は、その行だけ捨てる。1行のために報告ごと
        // 捨てると、ほかの枠まで「–」になる（実装を直したときに、別のエージェントのテストで見つかった）。
        check(
            "[5b] percent の無い行だけ捨て、ほかの枠は読む",
            U.claude(limitsLine([
                #"{"kind":"session","group":"session","resets_at":null}"#,
                row("weekly_all", group: q("weekly"), percent: "14"),
            ])),
            read(week: W("週", 14))
        )
        check(
            "[5b] kind が文字列でない行だけ捨て、ほかの枠は読む",
            U.claude(limitsLine([
                row("session", group: q("session"), percent: "3"),
                #"{"kind":7,"group":"weekly","percent":50}"#,
            ])),
            read(session: W("5時間", 3))
        )

        check(
            "[5b] scope の片方が決まった形でなくても、もう片方の名前を使う",
            U.claude(limitsLine([row("weekly_scoped", group: q("weekly"), percent: "5", scope: #"{"model":{"display_name":7},"surface":{"display_name":"Web"}}"#)])),
            read(others: [W("Web の週", 5)])
        )
        check(
            "[1b] result の行の usage_report が決まった形でなくても noPlan",
            U.claude(#"{"type":"result","subtype":"success","usage_report":"broken"}"#),
            .failed(.noPlan)
        )

        // MARK: [6] 取れないとき

        check("[6] rate_limits が null なら noPlan", U.claude(report(rateLimits: "null")), .failed(.noPlan))
        check(
            "[6] limits が null なら unreadable",
            U.claude(report(rateLimits: #"{"limits":null,"extra_usage":{"is_enabled":false}}"#)),
            .failed(.unreadable)
        )
        check("[6] limits が空の配列なら、どの枠も空の Usage", U.claude(limitsLine([])), .read(Usage()))
        check(
            "[6] limits が空なら others も空（Usage() と同じ）",
            describe(U.claude(limitsLine([]))),
            describe(read())
        )
        check("[6] rate_limits のキーが無ければ null と同じく noPlan（要確認）", U.claude(report(rateLimits: nil)), .failed(.noPlan))
        check(
            "[6] limits のキーが無ければ null と同じく unreadable（要確認）",
            U.claude(report(rateLimits: #"{"extra_usage":{"is_enabled":false}}"#)),
            .failed(.unreadable)
        )

        // MARK: [7] date(iso:)

        check(
            "[7] 小数秒6桁・+00:00（2026-10-28T10:20:00.364309+00:00）、小数秒も残す（要確認）",
            near(U.date(iso: "2026-10-28T10:20:00.364309+00:00"), at(utc, 2026, 10, 28, 10, 20).addingTimeInterval(0.364309)),
            near(at(utc, 2026, 10, 28, 10, 20).addingTimeInterval(0.364309), at(utc, 2026, 10, 28, 10, 20).addingTimeInterval(0.364309))
        )
        check("[7] 小数秒なし・+00:00", U.date(iso: "2026-11-03T22:00:00+00:00"), wholeReset)
        check("[7] 小数秒なし・Z", U.date(iso: "2026-11-03T22:00:00Z"), wholeReset)
        check(
            "[7] 小数秒1桁（.5）・Z、小数秒も残す（要確認）",
            near(U.date(iso: "2026-11-03T22:00:00.5Z"), wholeReset.addingTimeInterval(0.5)),
            near(wholeReset.addingTimeInterval(0.5), wholeReset.addingTimeInterval(0.5))
        )
        check(
            "[7] 小数秒1桁（.5）・+00:00、小数秒も残す（要確認）",
            near(U.date(iso: "2026-11-03T22:00:00.5+00:00"), wholeReset.addingTimeInterval(0.5)),
            near(wholeReset.addingTimeInterval(0.5), wholeReset.addingTimeInterval(0.5))
        )
        check("[7] +09:00 の時差も読む（日本時間の 7:00 は 22:00Z）", U.date(iso: "2026-11-04T07:00:00+09:00"), wholeReset)
        check("[7] 負の時差も読む（-05:00 の 17:00 は 22:00Z）", U.date(iso: "2026-11-03T17:00:00-05:00"), wholeReset)
        do {
            let digits = "123456789"
            var bad: [String] = []
            var count = 0
            for k in 1...digits.count {
                let fraction = String(digits.prefix(k))
                let seconds = Double("0." + fraction)!
                for (suffix, offset) in [("Z", 0.0), ("+00:00", 0.0), ("+09:00", -9 * 3600.0), ("-03:30", 3.5 * 3600)] {
                    count += 1
                    let text = "2026-11-03T22:00:00.\(fraction)\(suffix)"
                    let expected = wholeReset.addingTimeInterval(seconds + offset)
                    let got = U.date(iso: text)
                    if near(got, expected) != near(expected, expected) {
                        bad.append("\(text) → \(got.map { "\($0.timeIntervalSince1970)" } ?? "nil")（期待 \(expected.timeIntervalSince1970)）")
                    }
                }
            }
            checkEvery("[7] 小数秒1〜9桁と Z・+00:00・+09:00・-03:30 の組で、その瞬間（1ms 未満の誤差）（要確認）", cases: count, bad)
            // 小数秒をどこまで残すかに依らず、読めること・秒までは合うことは決めごとどおり。
            var badSeconds: [String] = []
            for k in 1...digits.count {
                let fraction = String(digits.prefix(k))
                for (suffix, offset) in [("Z", 0.0), ("+00:00", 0.0), ("+09:00", -9 * 3600.0), ("-03:30", 3.5 * 3600)] {
                    let text = "2026-11-03T22:00:00.\(fraction)\(suffix)"
                    let expected = wholeReset.addingTimeInterval(offset)
                    let got = U.date(iso: text)
                    if got.map({ floor($0.timeIntervalSince1970) }) != expected.timeIntervalSince1970 {
                        badSeconds.append("\(text) → \(got.map { "\($0.timeIntervalSince1970)" } ?? "nil")（期待 \(expected.timeIntervalSince1970) 台）")
                    }
                }
            }
            checkEvery("[7] 小数秒1〜9桁と Z・+00:00・+09:00・-03:30 の組で、読めて、秒までは合う", cases: count, badSeconds)
        }
        check("[7] でたらめな文字列は nil", U.date(iso: "garbage"), nil)
        check("[7] 空の文字列は nil", U.date(iso: ""), nil)
        check("[7] null という文字列は nil", U.date(iso: "null"), nil)
        check("[7] 月が 13 なら nil", U.date(iso: "2026-13-03T22:00:00Z"), nil)
        // 時差が無いと、どの時間帯の時刻か決まらない。この Mac の時間帯で読むと結果が Mac ごとに変わる。
        check("[7] 時差の無い日時は nil（要確認）", U.date(iso: "2026-11-03T22:00:00"), nil)

        // MARK: [8] rateLimits の要求への返事でなければ nil

        check("[8] 実際の返事（id は codexRequests から）は nil でない", U.codex(codexExample) == nil, false)
        check("[8] JSON でない文字列は nil", U.codex("Listening on stdio"), nil)
        check("[8] 空の文字列は nil", U.codex(""), nil)
        check(
            "[8] 通知（id 無し）は nil",
            U.codex(#"{"method":"codex/event/session_configured","params":{"msg":{"type":"session_configured"}}}"#),
            nil
        )
        check(
            "[8] 中身が rateLimits の通知でも、id が無ければ nil",
            U.codex(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1793183187},"secondary":null}}}"#),
            nil
        )
        check(
            "[8] initialize への返事（id 1）は nil",
            U.codex(#"{"id":1,"result":{"userAgent":"codex_cli_rs/0.1.0","codexHome":"/Users/x/.codex"}}"#),
            nil
        )
        check(
            "[8] initialize と同じ id の返事は、中身が rateLimits でも nil",
            U.codex(codexReply(primary: codexWindow(5, mins: "300"), secondary: "null", id: initializeID)),
            nil
        )
        check(
            "[8] 知らない id の返事は、中身が rateLimits でも nil",
            U.codex(codexReply(primary: codexWindow(5, mins: "300"), secondary: "null", id: "987654")),
            nil
        )
        check(
            "[8] 知らない id の error の返事も nil（unreadable ではない）",
            U.codex(#"{"id":987654,"error":{"code":-32600,"message":"bad"}}"#),
            nil
        )
        check(
            "[8] 配列の行は nil（中に rateLimits の返事があっても）",
            U.codex("[\(codexExample)]"),
            nil
        )

        // MARK: [9] codexRequests

        let requests = requestParts.dropLast().map(jsonObject)
        check("[9] 改行で終わる", UsageLimits.codexRequests.hasSuffix("\n"), true)
        check("[9] ちょうど3行（改行で切ると3行と、最後の改行の後ろの空）", requestParts.count, 4)
        check("[9] 最後の改行の後ろには何も無い", requestParts.last, "")
        check("[9] 3行とも JSON のオブジェクト", requests.map { $0 != nil }, [true, true, true])
        let first = requests.first ?? nil
        let second = requests.count > 1 ? requests[1] : nil
        let third = requests.count > 2 ? requests[2] : nil
        check("[9] 1行目は initialize", first?["method"] as? String, "initialize")
        check("[9] 1行目には id がある", jsonText(first?["id"]) != nil, true)
        let clientInfo = (first?["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        check("[9] 1行目の params.clientInfo.name は文字列", clientInfo?["name"] is String, true)
        check("[9] 1行目の params.clientInfo.version は文字列", clientInfo?["version"] is String, true)
        check("[9] 2行目は initialized の通知", second?["method"] as? String, "initialized")
        check("[9] 2行目（通知）には id が無い", second.map { $0["id"] == nil }, true)
        check("[9] 3行目は account/rateLimits/read", third?["method"] as? String, "account/rateLimits/read")
        check("[9] 3行目には id がある", jsonText(third?["id"]) != nil, true)
        check(
            "[9] 2つの要求の id は違う",
            jsonText(first?["id"]).flatMap { a in jsonText(third?["id"]).map { a != $0 } },
            true
        )
        check(
            "[9] 3行目の id で作った返事を codex(_:) が読む",
            U.codex(codexReply(primary: codexWindow(7, mins: "300"), secondary: "null", id: jsonText(third?["id"]) ?? "null")),
            read(session: W("5時間", 7))
        )

        // MARK: [10] 読めない返事

        check(
            "[10] error の返事は unreadable",
            U.codex(#"{"id":\#(rateLimitsID),"error":{"code":-32600,"message":"Invalid request"}}"#),
            .failed(.unreadable)
        )
        check(
            "[10] result に rateLimits が無ければ unreadable",
            U.codex(#"{"id":\#(rateLimitsID),"result":{"ordinaryUsageAllowed":true}}"#),
            .failed(.unreadable)
        )
        check(
            "[10] result が空のオブジェクトなら unreadable",
            U.codex(#"{"id":\#(rateLimitsID),"result":{}}"#),
            .failed(.unreadable)
        )
        check(
            "[10] rateLimits が null なら unreadable",
            U.codex(#"{"id":\#(rateLimitsID),"result":{"rateLimits":null}}"#),
            .failed(.unreadable)
        )
        check(
            "[10] result も error も無い返事は unreadable",
            U.codex(#"{"id":\#(rateLimitsID)}"#),
            .failed(.unreadable)
        )
        check(
            "[10] error があれば、result に rateLimits があっても unreadable（要確認）",
            U.codex(#"{"id":\#(rateLimitsID),"error":{"code":-1,"message":"x"},"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":null},"secondary":null}}}"#),
            .failed(.unreadable)
        )

        // MARK: [11] Codex の枠

        check(
            "[11] 実際の返事: primary 300 分は 5時間、secondary 10080 分は週",
            U.codex(codexExample),
            read(
                session: W("5時間", 0, Date(timeIntervalSince1970: 1_793_183_187)),
                week: W("週", 46, Date(timeIntervalSince1970: 1_793_644_644))
            )
        )
        check(
            "[11] どちらの欄かでなく長さで分ける（primary が 10080、secondary が 300）",
            U.codex(codexReply(primary: codexWindow(46, mins: "10080", resetsAt: "2000"), secondary: codexWindow(3, mins: "300", resetsAt: "1000"))),
            read(
                session: W("5時間", 3, Date(timeIntervalSince1970: 1000)),
                week: W("週", 46, Date(timeIntervalSince1970: 2000))
            )
        )
        check(
            "[11] 300 でも 10080 でもない長さは others に、spanName の名前で（1440 は 1日）",
            U.codex(codexReply(primary: codexWindow(12, mins: "1440"), secondary: "null")),
            read(others: [W("1日", 12)])
        )
        check(
            "[11] 長さが null なら others に「枠」で",
            U.codex(codexReply(primary: codexWindow(12, mins: "null"), secondary: "null")),
            read(others: [W("枠", 12)])
        )
        check(
            "[11] 長さのキーが無くても null と同じく others に「枠」で",
            U.codex(codexReply(primary: codexWindow(12, mins: nil), secondary: "null")),
            read(others: [W("枠", 12)])
        )
        check(
            "[11] 両方 300 なら primary が session、secondary は others に「5時間」で",
            U.codex(codexReply(primary: codexWindow(1, mins: "300"), secondary: codexWindow(2, mins: "300"))),
            read(session: W("5時間", 1), others: [W("5時間", 2)])
        )
        check(
            "[11] 両方 10080 なら primary が week、secondary は others に「週」で",
            U.codex(codexReply(primary: codexWindow(1, mins: "10080"), secondary: codexWindow(2, mins: "10080"))),
            read(week: W("週", 1), others: [W("週", 2)])
        )
        check(
            "[11] others は primary、secondary の順",
            U.codex(codexReply(primary: codexWindow(1, mins: "2880"), secondary: codexWindow(2, mins: "60"))),
            read(others: [W("2日", 1), W("1時間", 2)])
        )
        check(
            "[11] primary が null なら飛ばして secondary だけ",
            U.codex(codexReply(primary: "null", secondary: codexWindow(46, mins: "10080", resetsAt: "1793644644"))),
            read(week: W("週", 46, Date(timeIntervalSince1970: 1_793_644_644)))
        )
        check(
            "[11] secondary が null なら primary だけ",
            U.codex(codexReply(primary: codexWindow(3, mins: "300", resetsAt: "1793183187"), secondary: "null")),
            read(session: W("5時間", 3, Date(timeIntervalSince1970: 1_793_183_187)))
        )
        check("[11] 両方 null なら noPlan", U.codex(codexReply(primary: "null", secondary: "null")), .failed(.noPlan))
        check(
            "[11] primary・secondary のキーが両方無ければ null と同じく noPlan（要確認）",
            U.codex(#"{"id":\#(rateLimitsID),"result":{"rateLimits":{"limitId":"codex","credits":null,"planType":"plus"}}}"#),
            .failed(.noPlan)
        )
        check(
            "[11] usedPercent はそのまま percent に（100 は 100）",
            U.codex(codexReply(primary: codexWindow(100, mins: "300"), secondary: codexWindow(0, mins: "10080"))),
            read(session: W("5時間", 100), week: W("週", 0))
        )
        check(
            "[11] resetsAt が null なら nil",
            U.codex(codexReply(primary: codexWindow(3, mins: "300", resetsAt: "null"), secondary: "null")),
            read(session: W("5時間", 3, nil))
        )
        check(
            "[11] resetsAt のキーが無くても nil",
            U.codex(codexReply(primary: codexWindow(3, mins: "300", resetsAt: nil), secondary: "null")),
            read(session: W("5時間", 3, nil))
        )
        check(
            "[11] resetsAt は unix 秒（ミリ秒ではない）",
            U.codex(codexReply(primary: codexWindow(3, mins: "300", resetsAt: "1"), secondary: "null")),
            read(session: W("5時間", 3, Date(timeIntervalSince1970: 1)))
        )
        // 長さと null の全部の組で、決めごとの表から出る答えと比べる。
        do {
            let spans: [Int?] = [nil, 300, 10080, 1440, 60, 90, 20160, 0, -300]
            var sides: [(json: String, window: (percent: Int, minutes: Int?, reset: Int)?)] = [("null", nil)]
            for (i, m) in spans.enumerated() {
                let percent = 10 + i
                let reset = 1_793_000_000 + i * 1000
                sides.append((codexWindow(percent, mins: m.map(String.init) ?? "null", resetsAt: "\(reset)"), (percent, m, reset)))
            }
            var bad: [String] = []
            var count = 0
            for p in sides {
                for s in sides {
                    count += 1
                    // 区別できるように secondary の percent は 50 足す。
                    let sJSON = s.window.map { codexWindow($0.percent + 50, mins: $0.minutes.map(String.init) ?? "null", resetsAt: "\($0.reset + 1)") } ?? "null"
                    let present = [p.window, s.window.map { (percent: $0.percent + 50, minutes: $0.minutes, reset: $0.reset + 1) }].compactMap { $0 }
                    var session: Window?
                    var week: Window?
                    var others: [Window] = []
                    for w in present {
                        let window = W(U.spanName(minutes: w.minutes), Double(w.percent), Date(timeIntervalSince1970: TimeInterval(w.reset)))
                        if w.minutes == 300 && session == nil {
                            session = window
                        } else if w.minutes == 10080 && week == nil {
                            week = window
                        } else {
                            others.append(window)
                        }
                    }
                    let expected: State = present.isEmpty ? .failed(.noPlan) : read(session: session, week: week, others: others)
                    let got = U.codex(codexReply(primary: p.json, secondary: sJSON))
                    if got != expected {
                        bad.append("primary=\(p.json) secondary=\(sJSON) → \(describe(got))（期待 \(describe(expected))）")
                    }
                }
            }
            checkEvery("[11] primary・secondary の長さと null の全部の組で、決めごとの表どおり", cases: count, bad)
        }

        // MARK: [11b] Codex のほかの枠（rateLimitsByLimitId）
        //
        // 決めごとを足した: ふつうの枠（rateLimits、limitId は「codex」）のほかに、モデルごとなどの枠が
        // rateLimitsByLimitId に入ることがある。others に「<limitName、無ければ limitId> の<spanName>」で、
        // limitId の順に足す。ふつうの枠と同じ limitId のものは足さない（同じ枠が2回出る）。

        /// rateLimitsByLimitId 付きの返事。main の limitId は JSON のまま。
        func bucketsReply(main: String, mainID: String = q("codex"), byID: String) -> String {
            #"{"id":\#(rateLimitsID),"result":{"rateLimits":{"limitId":\#(mainID),"limitName":null,\#(main)},"rateLimitsByLimitId":\#(byID)}}"#
        }
        let mainWindows = #""primary":\#(codexWindow(10, mins: "300")),"secondary":\#(codexWindow(20, mins: "10080"))"#
        let mainEntry = #""codex":{"limitId":"codex","limitName":null,\#(mainWindows)}"#
        let spark = #""codex_spark":{"limitId":"codex_spark","limitName":"GPT-5.3-Codex-Spark","primary":\#(codexWindow(30, mins: "300", resetsAt: "1793183187")),"secondary":\#(codexWindow(40, mins: "10080"))}"#
        check(
            "[11b] ほかの枠は名前を付けて others に。ふつうの枠と同じ limitId は足さない",
            U.codex(bucketsReply(main: mainWindows, byID: "{\(mainEntry),\(spark)}")),
            read(
                session: W("5時間", 10), week: W("週", 20),
                others: [W("GPT-5.3-Codex-Spark の5時間", 30, Date(timeIntervalSince1970: 1793183187)), W("GPT-5.3-Codex-Spark の週", 40)]
            )
        )
        check(
            "[11b] limitName が無ければ limitId を名前に",
            U.codex(bucketsReply(main: mainWindows, byID: #"{"other":{"limitId":"other","limitName":null,"primary":\#(codexWindow(5, mins: "300")),"secondary":null}}"#)),
            read(session: W("5時間", 10), week: W("週", 20), others: [W("other の5時間", 5)])
        )
        check(
            "[11b] ほかの枠は limitId の順",
            U.codex(bucketsReply(main: mainWindows, byID: #"{"zz":{"limitName":"Z","primary":\#(codexWindow(1, mins: "300"))},"aa":{"limitName":"A","primary":\#(codexWindow(2, mins: "300"))}}"#)),
            read(session: W("5時間", 10), week: W("週", 20), others: [W("A の5時間", 2), W("Z の5時間", 1)])
        )
        check(
            "[11b] ふつうの枠の limitId が null なら「codex」をふつうの枠とみなす",
            U.codex(bucketsReply(main: mainWindows, mainID: "null", byID: "{\(mainEntry)}")),
            read(session: W("5時間", 10), week: W("週", 20))
        )
        check(
            "[11b] ふつうの枠が両方 null でも、ほかの枠があれば読めた（noPlan にしない）",
            U.codex(bucketsReply(main: #""primary":null,"secondary":null"#, byID: "{\(spark)}")),
            read(others: [W("GPT-5.3-Codex-Spark の5時間", 30, Date(timeIntervalSince1970: 1793183187)), W("GPT-5.3-Codex-Spark の週", 40)])
        )
        check(
            "[11b] ほかの枠の一覧が決まった形でなくても、ふつうの枠は読む",
            U.codex(bucketsReply(main: mainWindows, byID: q("broken"))),
            read(session: W("5時間", 10), week: W("週", 20))
        )

        check(
            "[11b] 一覧の中の読めない枠だけ捨て、ほかの枠は読む",
            U.codex(bucketsReply(main: mainWindows, byID: "{\(spark)," + #""bad":{"limitName":"B","primary":{"usedPercent":"x"}}}"#)),
            read(
                session: W("5時間", 10), week: W("週", 20),
                others: [W("GPT-5.3-Codex-Spark の5時間", 30, Date(timeIntervalSince1970: 1793183187)), W("GPT-5.3-Codex-Spark の週", 40)]
            )
        )

        // MARK: [12] spanName(minutes:)

        check("[12] nil は「枠」", U.spanName(minutes: nil), "枠")
        check("[12] 0 は「枠」", U.spanName(minutes: 0), "枠")
        check("[12] 負は「枠」", U.spanName(minutes: -60), "枠")
        check("[12] 負の 10080 も「枠」", U.spanName(minutes: -10080), "枠")
        check("[12] 10080 はちょうど「週」（1週ではない）", U.spanName(minutes: 10080), "週")
        check("[12] 20160 は「2週」", U.spanName(minutes: 20160), "2週")
        check("[12] 100800 は「10週」", U.spanName(minutes: 100_800), "10週")
        check("[12] 1440 は「1日」", U.spanName(minutes: 1440), "1日")
        check("[12] 2880 は「2日」", U.spanName(minutes: 2880), "2日")
        check("[12] 8640 は「6日」", U.spanName(minutes: 8640), "6日")
        check("[12] 11520（8日、週の倍数でない）は「8日」", U.spanName(minutes: 11520), "8日")
        check("[12] 43200（30日）は「30日」", U.spanName(minutes: 43200), "30日")
        check("[12] 60 は「1時間」", U.spanName(minutes: 60), "1時間")
        check("[12] 300 は「5時間」", U.spanName(minutes: 300), "5時間")
        check("[12] 1380（23時間）は「23時間」", U.spanName(minutes: 1380), "23時間")
        check("[12] 1500（25時間）は「25時間」", U.spanName(minutes: 1500), "25時間")
        check("[12] 10140（169時間）は「169時間」", U.spanName(minutes: 10140), "169時間")
        check("[12] 90 は「90分」", U.spanName(minutes: 90), "90分")
        check("[12] 1 は「1分」", U.spanName(minutes: 1), "1分")
        check("[12] 59 は「59分」", U.spanName(minutes: 59), "59分")
        check("[12] 1441 は「1441分」", U.spanName(minutes: 1441), "1441分")
        check("[12] 10081 は「10081分」", U.spanName(minutes: 10081), "10081分")
        do {
            var badRoundTrip: [String] = []
            var badUnit: [String] = []
            let values = Array(1...50_000) + [100_800, 1_008_000, 525_600, 999_999]
            for n in values {
                let name = U.spanName(minutes: n)
                if minutes(ofSpanName: name) != n { badRoundTrip.append("\(n) → \(name)") }
                // いちばん大きく割り切れる単位で書く。
                let tooSmall = (name.hasSuffix("分") && n % 60 == 0)
                    || (name.hasSuffix("時間") && n % 1440 == 0)
                    || (name.hasSuffix("日") && n % 10080 == 0)
                if tooSmall { badUnit.append("\(n) → \(name)") }
            }
            checkEvery("[12] 1〜50000 分ほかで、書いた名前を分に戻すと元の数（形は 週・<n>週・<n>日・<n>時間・<n>分）", cases: values.count, badRoundTrip)
            checkEvery("[12] 1〜50000 分ほかで、割り切れるいちばん大きい単位で書く", cases: values.count, badUnit)
            let nonPositive = Array(-20_000...0)
            checkEvery(
                "[12] 0 以下はどれも「枠」",
                cases: nonPositive.count,
                nonPositive.filter { U.spanName(minutes: $0) != "枠" }.map { "\($0) → \(U.spanName(minutes: $0))" }
            )
        }

        // MARK: [13] barText

        check("[13] 実際の1行（Claude）は「Claude 3% 週 14%」", U.barText("Claude", U.claude(claudeExample)), "Claude 3% 週 14%")
        check("[13] 実際の返事（Codex）は「Codex 0% 週 46%」", U.barText("Codex", U.codex(codexExample)), "Codex 0% 週 46%")
        check("[13] 両方あれば「<label> <session%> 週 <week%>」", U.barText("Claude", read(session: W("5時間", 3), week: W("週", 14))), "Claude 3% 週 14%")
        check("[13] session が無ければ week だけ", U.barText("Claude", read(week: W("週", 14))), "Claude 週 14%")
        check("[13] week が無ければ session だけ", U.barText("Claude", read(session: W("5時間", 3))), "Claude 3%")
        check(
            "[13] others は出さない（session・week と一緒でも）",
            U.barText("Claude", read(session: W("5時間", 3), week: W("週", 14), others: [W("Fable の週", 77)])),
            "Claude 3% 週 14%"
        )
        check("[13] others だけなら「<label> –」", U.barText("Claude", read(others: [W("Fable の週", 77)])), "Claude –")
        check("[13] 枠が1つも無ければ「<label> –」", U.barText("Claude", read()), "Claude –")
        check("[13] nil は「<label> –」", U.barText("Claude", nil), "Claude –")
        check("[13] notFound は「<label> –」", U.barText("Codex", .failed(.notFound)), "Codex –")
        check("[13] noPlan は「<label> –」", U.barText("Codex", .failed(.noPlan)), "Codex –")
        check("[13] unreadable は「<label> –」", U.barText("Codex", .failed(.unreadable)), "Codex –")
        check("[13] ダッシュは U+2013", U.barText("X", nil).unicodeScalars.last.map { $0.value }, 0x2013)
        check("[13] session の窓の名前は出さない", U.barText("Claude", read(session: W("変な名前", 3))), "Claude 3%")
        check("[13] week の前はいつも「週 」（窓の名前に依らない）", U.barText("Claude", read(week: W("7日", 14))), "Claude 週 14%")
        check("[13] 2.5 は半分を上へ丸めて 3%", U.barText("Claude", read(session: W("5時間", 2.5))), "Claude 3%")
        check("[13] 12.4 は 12%", U.barText("Claude", read(session: W("5時間", 12.4))), "Claude 12%")
        check("[13] 99.5 は 100%", U.barText("Claude", read(session: W("5時間", 99.5))), "Claude 100%")
        check("[13] 120 は 100% に抑える", U.barText("Claude", read(session: W("5時間", 120))), "Claude 100%")
        check("[13] -5 は 0% に抑える", U.barText("Claude", read(week: W("週", -5))), "Claude 週 0%")
        check("[13] 0 は 0%", U.barText("Claude", read(session: W("5時間", 0), week: W("週", 0))), "Claude 0% 週 0%")
        do {
            var random = UsageTestRandom(seed: 13)
            let pool: [Double] = [0, 3, 14, 2.5, 0.4, 0.5, 49.99, 99.5, 100, 120, -5, 12.345]
            let labels = ["Claude", "Codex", "C", "使用量"]
            var badOthers: [String] = []
            var badLabel: [String] = []
            var badShape: [String] = []
            let n = 5000
            for i in 0..<n {
                let percent = { (r: inout UsageTestRandom) -> Double in r.chance() ? r.pick(pool) : r.unit() * 130 - 10 }
                let session = random.chance() ? W(random.pick(["5時間", "枠"]), percent(&random)) : nil
                let week = random.chance() ? W("週", percent(&random)) : nil
                // others の名前は、ほかに出ようのない文字にしておく。
                let others = (0..<random.below(4)).map { W("他\(i)の\($0)", percent(&random)) }
                let label = random.pick(labels)
                let text = U.barText(label, read(session: session, week: week, others: others))
                let example = "session=\(describe(session)) week=\(describe(week)) others=\(others.count) → \(text)"
                if text != U.barText(label, read(session: session, week: week)) || text.contains("他") {
                    badOthers.append(example)
                }
                if !text.hasPrefix(label + " ") { badLabel.append(example) }
                let pt = { (w: Window) in Monitor.percentText(w.percent / 100) }
                let expected = session == nil && week == nil
                    ? "\(label) –"
                    : label + (session.map { " " + pt($0) } ?? "") + (week.map { " 週 " + pt($0) } ?? "")
                if text != expected { badShape.append("\(example)（期待 \(expected)）") }
            }
            checkEvery("[13] 多くの組で、others は書いた文字に影響しない", cases: n, badOthers)
            checkEvery("[13] 多くの組で、いつも「<label> 」で始まる", cases: n, badLabel)
            checkEvery("[13] 多くの組で、「<label>[ session%][ 週 week%]」か「<label> –」（% は Monitor.percentText）", cases: n, badShape)
            let failedStates: [State?] = [nil, .failed(.notFound), .failed(.noPlan), .failed(.unreadable), read(), read(others: [W("枠", 50)])]
            var badDash: [String] = []
            for label in labels {
                for s in failedStates where U.barText(label, s) != "\(label) –" {
                    badDash.append("\(label), \(describe(s)) → \(U.barText(label, s))")
                }
            }
            checkEvery("[13] 取れていないとき・枠の無いときは、どの label でも「<label> –」", cases: labels.count * failedStates.count, badDash)
        }

        // MARK: [14] detailText

        let now = at(tokyo, 2026, 10, 28, 15, 0)
        check(
            "[14] 実際の1行（Claude）を、2026-10-28 15:00 の東京で",
            U.detailText("Claude Code", command: "claude", U.claude(claudeExample), now: now, calendar: tokyo),
            "Claude Code 5時間 3%（19:20 まで）　週 14%（11/4 7:00 まで）　Fable の週 0%（11/4 7:00 まで）"
        )
        check(
            "[14] 同じ内容を Usage から直接",
            U.detailText("Claude Code", command: "claude", exampleState, now: now, calendar: tokyo),
            "Claude Code 5時間 3%（19:20 まで）　週 14%（11/4 7:00 まで）　Fable の週 0%（11/4 7:00 まで）"
        )
        check(
            "[14] 実際の返事（Codex）を、2026-10-28 15:00 の東京で",
            U.detailText("Codex", command: "codex", U.codex(codexExample), now: now, calendar: tokyo),
            "Codex 5時間 0%（19:26 まで）　週 46%（11/3 3:37 まで）"
        )
        check(
            "[14] 同じ1行でも UTC の暦なら UTC の時刻で",
            U.detailText("Claude Code", command: "claude", exampleState, now: at(utc, 2026, 10, 28, 6, 0), calendar: utc),
            "Claude Code 5時間 3%（10:20 まで）　週 14%（11/3 22:00 まで）　Fable の週 0%（11/3 22:00 まで）"
        )
        check(
            "[14] resetsAt が nil の窓は「<名前> <pct>」だけ",
            U.detailText("Claude Code", command: "claude", read(session: W("5時間", 3)), now: now, calendar: tokyo),
            "Claude Code 5時間 3%"
        )
        check(
            "[14] resetsAt のある窓と無い窓が混ざっても、それぞれの形で",
            U.detailText("Codex", command: "codex", read(session: W("5時間", 3), week: W("週", 14, at(tokyo, 2026, 10, 28, 23, 5))), now: now, calendar: tokyo),
            "Codex 5時間 3%　週 14%（23:05 まで）"
        )
        check(
            "[14] 順は session、week、others の順（Usage の中の並びで）",
            U.detailText(
                "C",
                command: "claude",
                read(session: W("5時間", 1), week: W("週", 2), others: [W("B の週", 3), W("A の週", 4)]),
                now: now,
                calendar: tokyo
            ),
            "C 5時間 1%　週 2%　B の週 3%　A の週 4%"
        )
        check(
            "[14] session が無ければ week から",
            U.detailText("C", command: "claude", read(week: W("週", 2), others: [W("Fable の週", 3)]), now: now, calendar: tokyo),
            "C 週 2%　Fable の週 3%"
        )
        check(
            "[14] others だけでも出す（「–」にしない）",
            U.detailText("C", command: "claude", read(others: [W("Fable の週", 3)]), now: now, calendar: tokyo),
            "C Fable の週 3%"
        )
        check("[14] 窓が1つも無ければ「<name> –」", U.detailText("Claude Code", command: "claude", read(), now: now, calendar: tokyo), "Claude Code –")
        check("[14] nil は「<name> –」", U.detailText("Claude Code", command: "claude", nil, now: now, calendar: tokyo), "Claude Code –")
        check(
            "[14] notFound はコマンド名を出す",
            U.detailText("Codex", command: "codex", .failed(.notFound), now: now, calendar: tokyo),
            "Codex –（codex コマンドが見つからない）"
        )
        check(
            "[14] notFound のコマンド名は渡したものをそのまま",
            U.detailText("Claude Code", command: "/opt/bin/claude", .failed(.notFound), now: now, calendar: tokyo),
            "Claude Code –（/opt/bin/claude コマンドが見つからない）"
        )
        // 決めごとを改めた: noPlan は API キーのときだけでなく、ログインしていない・CLI が古いときにも出る（[1b]）。
        check(
            "[14] noPlan",
            U.detailText("Claude Code", command: "claude", .failed(.noPlan), now: now, calendar: tokyo),
            "Claude Code –（プランの枠が出ない。API キーで使っているか、ログインしていないか、claude が古い）"
        )
        check(
            "[14] noPlan はそのコマンドの名前を出す",
            U.detailText("Codex", command: "codex", .failed(.noPlan), now: now, calendar: tokyo),
            "Codex –（プランの枠が出ない。API キーで使っているか、ログインしていないか、codex が古い）"
        )
        check(
            "[14] unreadable",
            U.detailText("Codex", command: "codex", .failed(.unreadable), now: now, calendar: tokyo),
            "Codex –（読めなかった）"
        )
        check(
            "[14] % は barText と同じ書き方（2.5 は 3%、120 は 100%、-5 は 0%）（要確認）",
            U.detailText("C", command: "claude", read(session: W("5時間", 2.5), week: W("週", 120), others: [W("枠", -5)]), now: now, calendar: tokyo),
            "C 5時間 3%　週 100%　枠 0%"
        )
        do {
            var random = UsageTestRandom(seed: 14)
            let names = ["5時間", "週", "Fable の週", "2日", "枠", "monthly"]
            var badParts: [String] = []
            var badDash: [String] = []
            let n = 3000
            for _ in 0..<n {
                let window = { (r: inout UsageTestRandom) -> Window in
                    let reset = r.chance() ? now.addingTimeInterval(Double(r.below(14 * 24 * 60)) * 60 - 2 * 86400) : nil
                    return W(r.pick(names), Double(r.below(101)), reset)
                }
                let session = random.chance() ? window(&random) : nil
                let week = random.chance() ? window(&random) : nil
                let others = (0..<random.below(4)).map { _ in window(&random) }
                let windows = [session, week].compactMap { $0 } + others
                let text = U.detailText("Name", command: "cmd", read(session: session, week: week, others: others), now: now, calendar: tokyo)
                if windows.isEmpty {
                    if text != "Name –" { badDash.append(text) }
                    continue
                }
                let expected = "Name " + windows.map { w in
                    "\(w.name) \(Monitor.percentText(w.percent / 100))" + (w.resetsAt.map { "（\(U.resetText($0, now: now, calendar: tokyo)) まで）" } ?? "")
                }.joined(separator: "\u{3000}")
                if text != expected { badParts.append("\(text)（期待 \(expected)）") }
            }
            checkEvery("[14] 多くの組で、「<name> 」の後に窓を session・week・others の順に全角空白でつなぐ", cases: n, badParts)
            checkEvery("[14] 多くの組で、窓の無いときだけ「<name> –」", cases: n, badDash)
        }

        // MARK: [15] resetText

        check("[15] 同じ日なら H:mm（19:20）", U.resetText(at(tokyo, 2026, 10, 28, 19, 20), now: now, calendar: tokyo), "19:20")
        check("[15] 時は0で埋めない（7:05）", U.resetText(at(tokyo, 2026, 10, 28, 7, 5), now: now, calendar: tokyo), "7:05")
        check("[15] 0 時は 0:00", U.resetText(at(tokyo, 2026, 10, 28, 0, 0), now: now, calendar: tokyo), "0:00")
        check("[15] 23:59", U.resetText(at(tokyo, 2026, 10, 28, 23, 59), now: now, calendar: tokyo), "23:59")
        check("[15] 同じ日なら now より前でも H:mm（9:00）", U.resetText(at(tokyo, 2026, 10, 28, 9, 0), now: now, calendar: tokyo), "9:00")
        check("[15] now ちょうどなら H:mm", U.resetText(now, now: now, calendar: tokyo), "15:00")
        check("[15] 違う日なら M/d H:mm、0で埋めない（11/4 7:00）", U.resetText(at(tokyo, 2026, 11, 4, 7, 0), now: now, calendar: tokyo), "11/4 7:00")
        check("[15] 翌日の 0:00 は違う日（10/29 0:00）", U.resetText(at(tokyo, 2026, 10, 29, 0, 0), now: now, calendar: tokyo), "10/29 0:00")
        check("[15] 前の日なら M/d H:mm（10/27 23:59）", U.resetText(at(tokyo, 2026, 10, 27, 23, 59), now: now, calendar: tokyo), "10/27 23:59")
        check("[15] 2桁の月日（12/25 18:30）", U.resetText(at(tokyo, 2026, 12, 25, 18, 30), now: now, calendar: tokyo), "12/25 18:30")
        check(
            "[15] 年をまたいだ翌日（1/1 0:30）",
            U.resetText(at(tokyo, 2027, 1, 1, 0, 30), now: at(tokyo, 2026, 12, 31, 23, 0), calendar: tokyo),
            "1/1 0:30"
        )
        check(
            "[15] 月日が同じでも年が違えば違う日（10/28 15:00）",
            U.resetText(at(tokyo, 2027, 10, 28, 15, 0), now: now, calendar: tokyo),
            "10/28 15:00"
        )
        check(
            "[15] now が 23:59 で 1 分後の 0:00 は違う日",
            U.resetText(at(tokyo, 2026, 10, 29, 0, 0), now: at(tokyo, 2026, 10, 28, 23, 59), calendar: tokyo),
            "10/29 0:00"
        )
        // 決めごとを改めた: いちばん近い分に丸める。Claude Code の時刻は聞くたびに1秒たらずずれ（10:19:59.87 など）、
        // 切り捨てると `/usage` の 7:20pm に対して 19:19 と出た。
        check(
            "[15b] 秒はいちばん近い分に丸める（7:59:59.9 は 8:00）",
            U.resetText(at(tokyo, 2026, 10, 28, 7, 59, 59).addingTimeInterval(0.9), now: now, calendar: tokyo),
            "8:00"
        )
        check(
            "[15b] 29 秒は切り下げ（7:59:29 は 7:59）",
            U.resetText(at(tokyo, 2026, 10, 28, 7, 59, 29), now: now, calendar: tokyo),
            "7:59"
        )
        check(
            "[15b] 30 秒ちょうどは切り上げ（7:59:30 は 8:00）",
            U.resetText(at(tokyo, 2026, 10, 28, 7, 59, 30), now: now, calendar: tokyo),
            "8:00"
        )
        check(
            "[15b] 日付は丸めたあとの時刻で決める（同じ日の 23:59:45 は翌日の 0:00）",
            U.resetText(at(tokyo, 2026, 10, 28, 23, 59, 45), now: now, calendar: tokyo),
            "10/29 0:00"
        )
        // 同じ2つの瞬間でも、暦の時間帯で同じ日かどうかが変わる。
        let late = at(utc, 2026, 10, 28, 16, 0)
        let morning = at(utc, 2026, 10, 28, 10, 0)
        check("[15] UTC の暦では同じ日なので 16:00", U.resetText(late, now: morning, calendar: utc), "16:00")
        check("[15] 同じ瞬間でも東京の暦では翌日の 1:00", U.resetText(late, now: morning, calendar: tokyo), "10/29 1:00")
        check(
            "[15] ニューヨークの暦では前の日の夜でも同じ日（10/27 の 20:00 と 23:00）",
            U.resetText(at(utc, 2026, 10, 28, 3, 0), now: at(utc, 2026, 10, 28, 0, 0), calendar: makeCalendar("America/New_York")),
            "23:00"
        )
        do {
            let zones = [
                "Asia/Tokyo", "UTC", "America/New_York", "Pacific/Kiritimati", "Pacific/Pago_Pago",
                "Asia/Kolkata", "Australia/Lord_Howe", "America/St_Johns",
            ]
            let dates = [
                at(utc, 2026, 10, 28, 10, 20),
                at(utc, 2026, 11, 1, 6, 30),  // ニューヨークの夏時間の終わり
                at(utc, 2026, 12, 31, 23, 45),  // 年の境目
                at(utc, 2027, 3, 14, 7, 0),  // ニューヨークの夏時間の始まり
                at(utc, 2026, 10, 3, 15, 45),  // ロード・ハウ島の夏時間の始まり（30 分ずれる）
            ]
            var badSlash: [String] = []
            var badText: [String] = []
            var count = 0
            for defaultZone in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
                // この Mac（プロセス）の時間帯を変えても、結果は暦の時間帯だけで決まる。
                NSTimeZone.default = TimeZone(identifier: defaultZone)!
                for zone in zones {
                    let cal = makeCalendar(zone)
                    for date in dates {
                        for k in -120...120 {
                            count += 1
                            let current = date.addingTimeInterval(Double(k) * 37 * 60)
                            let text = U.resetText(date, now: current, calendar: cal)
                            let sameDay = cal.isDate(date, inSameDayAs: current)
                            let example = "既定 \(defaultZone)、暦 \(zone)、\(date) と now \(current) → \(text)"
                            if text.contains("/") == sameDay { badSlash.append(example) }
                            let c = cal.dateComponents([.month, .day, .hour, .minute], from: date)
                            let expected = (sameDay ? "" : "\(c.month!)/\(c.day!) ") + "\(c.hour!):" + String(format: "%02d", c.minute!)
                            if text != expected { badText.append("\(example)（期待 \(expected)）") }
                        }
                    }
                }
            }
            NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!
            checkEvery("[15] 8 つの時間帯と多くの now で、「/」が入るのは暦の上で日が違うときだけ", cases: count, badSlash)
            checkEvery("[15] 8 つの時間帯と多くの now で、暦の時間帯の M/d H:mm か H:mm", cases: count, badText)
        }

        // MARK: [16] Monitor.columns

        check("[16] claude のすぐ後の codex は1列", columnTexts([.claude, .codex]), [["claude", "codex"]])
        check("[16] 前の詰めかけの1行は先に1行の列に（disk）", columnTexts([.disk, .claude, .codex]), [["disk"], ["claude", "codex"]])
        check("[16] 前が2行で埋まっていればそのまま", columnTexts([.cpu, .memory, .claude, .codex]), [["cpu", "memory"], ["claude", "codex"]])
        check(
            "[16] down/up の組、1行、claude/codex の組",
            columnTexts([.down, .up, .cpu, .claude, .codex]),
            [["down", "up"], ["cpu"], ["claude", "codex"]]
        )
        check("[16] codex の後の claude は組ではない", columnTexts([.cpu, .codex, .claude]), [["cpu", "codex"], ["claude"]])
        check("[16] codex の続かない claude はふつうの行", columnTexts([.cpu, .claude]), [["cpu", "claude"]])
        check("[16] codex、claude の順は組ではない", columnTexts([.codex, .claude]), [["codex", "claude"]])
        check("[16] claude だけなら1行の列", columnTexts([.claude]), [["claude"]])
        check("[16] codex だけなら1行の列", columnTexts([.codex]), [["codex"]])
        check("[16] 組の後のほかの行は、また2つずつ", columnTexts([.claude, .codex, .cpu, .memory, .disk]), [["claude", "codex"], ["cpu", "memory"], ["disk"]])
        check("[16] claude/codex の組の後の down/up の組", columnTexts([.claude, .codex, .down, .up]), [["claude", "codex"], ["down", "up"]])
        check("[16] down/up の組のすぐ後の claude/codex の組", columnTexts([.down, .up, .claude, .codex]), [["down", "up"], ["claude", "codex"]])
        check("[16] claude が2つ続いたら、組になるのは codex の直前の claude", columnTexts([.claude, .claude, .codex]), [["claude"], ["claude", "codex"]])
        check("[16] 間に別の行がある claude と codex は組ではない", columnTexts([.claude, .cpu, .codex]), [["claude", "cpu"], ["codex"]])
        check("[16] claude の後の up は組ではない", columnTexts([.claude, .up]), [["claude", "up"]])
        check("[16] down の後の codex は組ではない", columnTexts([.down, .codex]), [["down", "codex"]])
        check("[16] up の続かない down の後の claude/codex の組", columnTexts([.down, .claude, .codex]), [["down"], ["claude", "codex"]])
        check("[16] これまでどおり: down/up は1列", columnTexts([.down, .up]), [["down", "up"]])
        check("[16] これまでどおり: 組の前の1行は先に閉じる", columnTexts([.cpu, .down, .up]), [["cpu"], ["down", "up"]])
        check("[16] これまでどおり: ほかの行は2つずつ", columnTexts([.cpu, .memory, .disk]), [["cpu", "memory"], ["disk"]])
        do {
            let kinds: [Kind] = [.down, .up, .cpu, .memory, .disk, .claude, .codex]
            var inputs: [[Kind]] = [[]]
            var frontier: [[Kind]] = [[]]
            for _ in 1...6 {
                frontier = frontier.flatMap { seq in kinds.map { seq + [$0] } }
                inputs += frontier
            }
            let isPair = { (a: Kind, b: Kind) in (a == .down && b == .up) || (a == .claude && b == .codex) }
            var badFlat: [String] = []
            var badSize: [String] = []
            var badPair: [String] = []
            var badSingle: [String] = []
            for input in inputs {
                // 同じ種類が並んでも区別できるように、text は元の位置にする。
                let rows = input.enumerated().map { Line(kind: $1, text: "\($0)") }
                let result = Monitor.columns(rows)
                let example = "\(input.map { "\($0)" }) → \(result.map { $0.map(\.text) })"
                if result.flatMap({ $0 }) != rows { badFlat.append(example) }
                if !result.allSatisfy({ (1...2).contains($0.count) }) { badSize.append(example) }
                for i in rows.indices.dropLast() where isPair(input[i], input[i + 1]) {
                    if !result.contains([rows[i], rows[i + 1]]) { badPair.append(example) }
                }
                for (j, column) in result.enumerated() where column.count == 1 {
                    let last = j == result.count - 1
                    let next = last ? [] : result[j + 1].map(\.kind)
                    let beforePair = next.count == 2 && isPair(next[0], next[1])
                    if !last && !beforePair { badSingle.append(example) }
                }
            }
            checkEvery("[16] 7 種類の行を 0〜6 行並べた全部の並びで、列を順に平らにすると元の並び", cases: inputs.count, badFlat)
            checkEvery("[16] 全部の並びで、どの列も1行か2行", cases: inputs.count, badSize)
            checkEvery("[16] 全部の並びで、down のすぐ後の up、claude のすぐ後の codex は、その2つだけで1列", cases: inputs.count, badPair)
            checkEvery("[16] 全部の並びで、1行の列は最後か、組の列の直前にだけある", cases: inputs.count, badSingle)
        }

        // MARK: [17] Monitor.Item

        check("[17] 既定は network・cpu・memory・disk（使用量は CLI を起動するので入れない）", Monitor.Item.defaults, [.network, .cpu, .memory, .disk])
        check("[17] 既定に claude は無い", Monitor.Item.defaults.contains(.claude), false)
        check("[17] 既定に codex は無い", Monitor.Item.defaults.contains(.codex), false)
        check("[17] claude はコマンドを尋ねる", Monitor.Item.claude.asksCommand, true)
        check("[17] codex はコマンドを尋ねる", Monitor.Item.codex.asksCommand, true)
        for item in [Monitor.Item.network, .cpu, .memory, .disk] {
            check("[17] \(item.rawValue) はコマンドを尋ねない", item.asksCommand, false)
        }
        check("[17] 全部の項目で、コマンドを尋ねるのは claude と codex だけ", Monitor.Item.allCases.filter(\.asksCommand), [.claude, .codex])

        print(failures == 0 ? "\nすべて通った" : "\n\(failures) 件失敗")
        exit(failures == 0 ? 0 : 1)
    }
}
