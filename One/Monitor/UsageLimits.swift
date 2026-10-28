import Foundation

/// Claude Code と Codex の使用量の枠（5時間・週）の読み方と書き方。
///
/// CLI が出した1行の JSON を受け取って枠の並びにし、メニューバーとメニューに出す文字にする。
/// コマンドを走らせるのは `UsageReader`。ここは OS にも画面にも触らないので、テストで確かめられる。
enum UsageLimits {
    /// 枠1つ。
    struct Window: Equatable {
        /// メニューに出す名前。「5時間」「週」「Fable の週」
        var name: String
        /// 使った割合。0〜100（CLI が出した数のまま）
        var percent: Double
        /// 枠が戻る時刻。分からなければ nil
        var resetsAt: Date?
    }

    /// 1つの道具の枠。
    struct Usage: Equatable {
        /// 5時間の枠
        var session: Window?
        /// 週の枠（全部のモデルを合わせたもの）
        var week: Window?
        /// それ以外（モデルごとの週の枠など）。メニューにだけ出す。並びは CLI が出した順
        var others: [Window] = []
    }

    /// 枠が読めなかったわけ。メニューに出し分ける。
    enum Failure: Equatable {
        /// コマンドが見つからない（入っていない、ログインシェルの PATH に無い）
        case notFound
        /// 走ったが、プランの枠を出さなかった（API キーで使っている、ログインしていない、CLI が古い、など）
        case noPlan
        /// 走ったが、枠を読み取れなかった（ネットにつながらない、出力の形が変わった、時間切れ）
        case unreadable
    }

    enum State: Equatable {
        case read(Usage)
        case failed(Failure)
    }

    // MARK: - Claude Code

    /// `claude -p /usage --output-format stream-json --verbose` の出力の1行から、枠を読む。
    /// 枠の報告（`usage_report`）の行でなければ nil。ただし、報告が来ないまま終わりの行（`"type":"result"`）が
    /// 来たら、プランの枠が無い（`.noPlan`）。報告は、新しい CLI で claude.ai のプランを使っているときにしか
    /// 付かない（Claude Code の型の説明）。終わりの行は報告の行の後に来る。
    ///
    /// 行は `kind` で見分ける。名前（`display_name`）で見分けない、と Claude Code の型の説明にある。
    /// `session` が5時間、`weekly_all` が週。それ以外（モデルごとの `weekly_scoped` など）は others に入れ、
    /// 範囲の名前と `group` から名前を付ける。サーバーが新しい枠を足しても、読み落とさずにメニューに出る。
    static func claude(_ line: String) -> State? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(ClaudeLine.self, from: Data(line.utf8)) else { return nil }
        guard let report = decoded.usageReport else { return decoded.type == "result" ? .failed(.noPlan) : nil }
        // rate_limits が null なのは、プランの枠が無いとき（API キー、Bedrock など）。
        guard let rateLimits = report.rateLimits else { return .failed(.noPlan) }
        // limits が null なのは、Claude Code が枠を取りに行って失敗している間。
        guard let limits = rateLimits.limits else { return .failed(.unreadable) }

        var usage = Usage()
        for limit in limits.compactMap(\.value) {
            let resetsAt = limit.resetsAt.flatMap(date(iso:))
            switch limit.kind {
            case "session" where usage.session == nil:
                usage.session = Window(name: "5時間", percent: limit.percent, resetsAt: resetsAt)
            case "weekly_all" where usage.week == nil:
                usage.week = Window(name: "週", percent: limit.percent, resetsAt: resetsAt)
            default:
                let group = limit.group.map(groupName) ?? limit.kind
                let scope = [limit.scope?.model?.displayName, limit.scope?.surface?.displayName]
                    .compactMap { $0 }.first { !$0.isEmpty }
                let name = scope.map { "\($0) の\(group)" } ?? group
                usage.others.append(Window(name: name, percent: limit.percent, resetsAt: resetsAt))
            }
        }
        return .read(usage)
    }

    /// Claude Code の `group`（行のまとまり）の名前。
    private static func groupName(_ group: String) -> String {
        switch group {
        case "session": "5時間"
        case "weekly": "週"
        default: group
        }
    }

    /// 「2026-10-28T10:20:00.364309+00:00」の形の時刻。読めなければ nil。
    ///
    /// 秒の小数は付くことも付かないこともある（同じ出力の中でも混ざる）。`ISO8601DateFormatter` は、小数を読む
    /// 設定にすると小数の無い形を読めず、しないと小数のある形を読めない（確かめた）。両方で試す。
    static func date(iso text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private struct ClaudeLine: Decodable {
        var type: String?
        var usageReport: Report?

        /// 報告が決まった形でなくても、終わりの行（type）は見分けられるように、欄ごとに読む。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decode(String.self, forKey: .type)
            usageReport = try? container.decode(Report.self, forKey: .usageReport)
        }

        enum CodingKeys: String, CodingKey {
            case type, usageReport
        }

        struct Report: Decodable {
            var rateLimits: RateLimits?
        }
        struct RateLimits: Decodable {
            /// 読めない行は、その行だけ捨てる。1行のために報告ごと捨てると、ほかの枠まで「–」になる
            var limits: [Lossy<Limit>]?
        }
        struct Limit: Decodable {
            var kind: String
            var group: String?
            var percent: Double
            var resetsAt: String?
            var scope: Scope?

            /// 種類と割合が読めなければ、その行は読めない。ほかの欄は、決まった形から外れていたら無いものとして読む。
            /// サーバーが送ってくる行なので、欄の形が変わることがありうる。
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = try container.decode(String.self, forKey: .kind)
                percent = try container.decode(Double.self, forKey: .percent)
                group = try? container.decode(String.self, forKey: .group)
                resetsAt = try? container.decode(String.self, forKey: .resetsAt)
                scope = try? container.decode(Scope.self, forKey: .scope)
            }

            enum CodingKeys: String, CodingKey {
                case kind, group, percent, resetsAt, scope
            }
        }
        struct Scope: Decodable {
            var model: Label?
            var surface: Label?

            /// 片方が決まった形でなくても、もう片方の名前は使う。
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                model = try? container.decode(Label.self, forKey: .model)
                surface = try? container.decode(Label.self, forKey: .surface)
            }

            enum CodingKeys: String, CodingKey {
                case model, surface
            }
        }
        struct Label: Decodable {
            var displayName: String?
        }
    }

    /// 読めなかった要素を、配列ごと捨てずに nil にする。
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    // MARK: - Codex

    /// `codex app-server` に送る問い合わせ。1行に1つの JSON-RPC。
    ///
    /// 始めの挨拶（`initialize` と `initialized`）を済ませないと、ほかの問い合わせを受け付けない。
    /// 返事が来るまで標準入力を閉じない。閉じると app-server は返事を出す前に終わる（確かめた）。
    static let codexRequests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"one","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized"}"#,
        #"{"jsonrpc":"2.0","id":\#(codexRateLimitsID),"method":"account/rateLimits/read"}"#,
    ].map { $0 + "\n" }.joined()

    /// `account/rateLimits/read` に付けた番号。返事はこの番号で見分ける。
    private static let codexRateLimitsID = 2

    /// `codex app-server` の出力の1行が `account/rateLimits/read` への返事なら、そこから枠を読む。
    /// 返事でなければ（知らせや、ほかの問い合わせへの返事なら）nil。
    ///
    /// 枠は長さ（`windowDurationMins`）で見分ける。300 分が5時間、10080 分が週。primary が5時間、
    /// secondary が週のことが多いが、プランによって違いうるので、どちらに入っているかでは決めない。
    ///
    /// ふつうの枠（`rateLimits`）のほかに、モデルごとなどの枠が `rateLimitsByLimitId` に入ることがある。
    /// それは others に、枠の名前（`limitName`、無ければ `limitId`）を付けて入れる。並びは `limitId` の順。
    static func codex(_ line: String) -> State? {
        guard let reply = try? JSONDecoder().decode(CodexReply.self, from: Data(line.utf8)),
              reply.id == codexRateLimitsID else { return nil }
        guard !reply.hasError, let result = reply.result, let snapshot = result.rateLimits else { return .failed(.unreadable) }

        var usage = Usage()
        for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
            let read = codexWindow(window, name: spanName(minutes: window.windowDurationMins))
            switch window.windowDurationMins {
            case 300 where usage.session == nil: usage.session = read
            case 10080 where usage.week == nil: usage.week = read
            default: usage.others.append(read)
            }
        }
        // ふつうの枠も、この一覧に同じ limitId で入っている（「codex」）。
        let mainID = snapshot.limitId ?? "codex"
        for (id, extra) in (result.rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key }) where id != mainID {
            for window in [extra.primary, extra.secondary].compactMap({ $0 }) {
                let name = "\(extra.limitName ?? id) の\(spanName(minutes: window.windowDurationMins))"
                usage.others.append(codexWindow(window, name: name))
            }
        }
        guard usage.session != nil || usage.week != nil || !usage.others.isEmpty else { return .failed(.noPlan) }
        return .read(usage)
    }

    private static func codexWindow(_ window: CodexReply.Window, name: String) -> Window {
        Window(name: name, percent: window.usedPercent, resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    /// 枠の長さ（分）の名前。「5時間」「週」「2週」「1日」「90分」。分からなければ「枠」。
    static func spanName(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "枠" }
        let week = 7 * 24 * 60
        if minutes % week == 0 { return minutes == week ? "週" : "\(minutes / week)週" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))日" }
        if minutes % 60 == 0 { return "\(minutes / 60)時間" }
        return "\(minutes)分"
    }

    private struct CodexReply: Decodable {
        var id: Int?
        /// `error` があれば、`result` は見ない（JSON-RPC では両方が来ることは無いはず）
        var hasError: Bool
        var result: Result?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(Int.self, forKey: .id)
            hasError = container.contains(.error) && (try? container.decodeNil(forKey: .error)) != true
            result = try? container.decode(Result.self, forKey: .result)
        }

        enum CodingKeys: String, CodingKey {
            case id, error, result
        }

        struct Result: Decodable {
            var rateLimits: Snapshot?
            var rateLimitsByLimitId: [String: Snapshot]?

            /// ほかの枠の一覧が読めなくても、ふつうの枠は読む。一覧の中の読めない枠は、その枠だけ捨てる。
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                rateLimits = try container.decodeIfPresent(Snapshot.self, forKey: .rateLimits)
                rateLimitsByLimitId = (try? container.decode([String: Lossy<Snapshot>].self, forKey: .rateLimitsByLimitId))?
                    .compactMapValues(\.value)
            }

            enum CodingKeys: String, CodingKey {
                case rateLimits, rateLimitsByLimitId
            }
        }
        struct Snapshot: Decodable {
            var limitId: String?
            var limitName: String?
            var primary: Window?
            var secondary: Window?
        }
        struct Window: Decodable {
            var usedPercent: Double
            var windowDurationMins: Int?
            var resetsAt: Int?
        }
    }

    // MARK: - 書き方

    /// メニューバーの1行。「Claude 3% 週 14%」。
    ///
    /// 5時間の枠は名前を付けずに先に、週の枠は「週」を付けて後に出す。狭いメニューバーでは、よく見るほうに
    /// 字数を使わない。片方しか無ければ、ある方だけ。まだ聞けていない・読めなかった・どちらの枠も無いときは
    /// 「Claude –」。
    static func barText(_ label: String, _ state: State?) -> String {
        guard case .read(let usage)? = state else { return "\(label) –" }
        let parts = [
            usage.session.map { percentText($0.percent) },
            usage.week.map { "週 " + percentText($0.percent) },
        ].compactMap { $0 }
        return parts.isEmpty ? "\(label) –" : ([label] + parts).joined(separator: " ")
    }

    /// メニューの1行。「Claude Code 5時間 3%（19:20 まで）　週 14%（11/4 7:00 まで）　Fable の週 0%（11/4 7:00 まで）」。
    ///
    /// 枠は5時間・週・それ以外の順。読めなかったときは、わけを括弧で添える。
    /// - name: 道具の名前（「Claude Code」）
    /// - command: 見つからなかったときに名前を出すコマンド（「claude」）
    /// - now, calendar: 戻る時刻を今日の時刻だけで書くか、日付も付けるかを決める
    static func detailText(_ name: String, command: String, _ state: State?, now: Date, calendar: Calendar) -> String {
        switch state {
        case nil:
            return "\(name) –"
        case .failed(.notFound)?:
            return "\(name) –（\(command) コマンドが見つからない）"
        case .failed(.noPlan)?:
            return "\(name) –（プランの枠が出ない。API キーで使っているか、ログインしていないか、\(command) が古い）"
        case .failed(.unreadable)?:
            return "\(name) –（読めなかった）"
        case .read(let usage)?:
            let windows = [usage.session, usage.week].compactMap { $0 } + usage.others
            guard !windows.isEmpty else { return "\(name) –" }
            let parts = windows.map { window in
                let text = "\(window.name) \(percentText(window.percent))"
                guard let resetsAt = window.resetsAt else { return text }
                return "\(text)（\(resetText(resetsAt, now: now, calendar: calendar)) まで）"
            }
            return "\(name) " + parts.joined(separator: "　")
        }
    }

    /// 枠が戻る時刻。今日なら「19:20」、ほかの日なら「11/4 7:00」。いちばん近い分に丸める（30 秒は切り上げ）。
    ///
    /// Claude Code が出す時刻は、聞くたびに1秒たらずずれる（「10:20:00.36」のときも「10:19:59.87」のときもある）。
    /// 切り捨てると、`/usage` が 7:20pm と出しているのに 19:19 と出てしまう。
    static func resetText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let minute = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: minute)
        let time = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(minute, inSameDayAs: now) { return time }
        return "\(parts.month ?? 0)/\(parts.day ?? 0) \(time)"
    }

    /// 割合（0〜100）の書き方。ほかの数字と同じ書き方にそろえる（`Monitor.percentText` は 0〜1 を受け取る）。
    private static func percentText(_ percent: Double) -> String {
        Monitor.percentText(percent / 100)
    }
}
