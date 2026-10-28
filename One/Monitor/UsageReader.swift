import Darwin
import Foundation

/// Claude Code と Codex に、使用量の枠を聞く。
///
/// どちらも、その CLI が用意している口で聞く。Claude Code は `/usage` を画面なしで走らせた出力
/// （`usage_report`）、Codex は `codex app-server`（IDE の拡張機能が使う JSON-RPC）の
/// `account/rateLimits/read`。モデルは呼ばないので、使用量は増えない。Keychain のログイン情報を読んで、
/// 公開されていない HTTP の口を直接たたくことはしない。
///
/// ここはコマンドを走らせて、答えの1行を拾うだけ。読むのは `UsageLimits`。
enum UsageReader {
    /// 聞く。終わるまで数秒かかる（Claude Code で 1.5 秒、Codex で 1 秒ほど）。
    static func read(_ item: Monitor.Item) async -> UsageLimits.State {
        await withCheckedContinuation { continuation in
            // コマンドが終わるのを待つ間、止まって待つ。メインスレッドを止めないよう、別のスレッドで。
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readBlocking(item))
            }
        }
    }

    private static func readBlocking(_ item: Monitor.Item) -> UsageLimits.State {
        switch item {
        case .claude:
            // フックと MCP のサーバーは要らないので止める。フックは、その人の設定でコマンドが
            // 何でも走りうる。会話の記録も残さない（`claude --resume` の一覧に出ないように）。
            let outcome = run(
                [
                    "claude", "-p", "/usage", "--output-format", "stream-json", "--verbose",
                    "--no-session-persistence", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
                ],
                input: nil,
                answer: UsageLimits.claude
            )
            return state(outcome, "claude")
        case .codex:
            let outcome = run(["codex", "app-server"], input: UsageLimits.codexRequests, answer: UsageLimits.codex)
            return state(outcome, "codex")
        case .network, .cpu, .memory, .disk:
            preconditionFailure("\(item) は CLI に聞くものではない")
        }
    }

    private static func state(_ outcome: Outcome, _ command: String) -> UsageLimits.State {
        switch outcome {
        case .answer(let state):
            return state
        case .notFound:
            log.debug("\(command, privacy: .public) が見つからない")
            return .failed(.notFound)
        case .noAnswer(let status):
            log.debug("\(command, privacy: .public) から答えが来なかった 終わり方=\(status, privacy: .public)")
            return .failed(.unreadable)
        }
    }

    // MARK: - 走らせる

    private enum Outcome {
        case answer(UsageLimits.State)
        /// シェルがコマンドを見つけられなかった（127 で終わった）
        case notFound
        /// 答えの行が来ないまま終わった、または時間切れ。終わり方（終了コード）を添える
        case noAnswer(Int32)
    }

    /// 答えを待つ長さ。ふつうは2秒かからない。ネットが遅いときに待ちすぎない程度に。
    private static let timeout: TimeInterval = 30

    /// `command` をログインシェル越しに走らせ、標準出力の行を `answer` に1行ずつ渡す。nil でない値が返ったら、
    /// それを答えにして止める。
    ///
    /// ログインシェル越しに走らせるのは、Finder から起動したアプリにはターミナルの PATH が渡らないから
    /// （`/usr/bin:/bin:/usr/sbin:/sbin` だけ）。nvm などで入れた CLI は `.zshrc` で PATH に足されるので、
    /// 対話のシェル（`-i`）にもする。ターミナルで打つのと同じ claude・codex が、同じ環境変数で走る。
    ///
    /// - input: 標準入力に書くもの。nil なら何も渡さない。書いたあとも、答えが来るまで閉じない
    private static func run(_ command: [String], input: String?, answer: @escaping (String) -> UsageLimits.State?) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        // `$0` と `$@` に渡すと、引数をシェルの文字列に組み込まずに済む（JSON の引数の引用符を気にしなくてよい）。
        process.arguments = ["-l", "-i", "-c", #"exec "$0" "$@""#] + command
        // どこで走らせても答えは同じ。ホームなどで走らせて、そこの設定を読まないように。
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        // 対話のシェルは、端末が無いと注意を出す（`can't change option: zle`）。読まないので捨てる。
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        let lines = LineReader(answer: answer)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // 出力が終わると、空の切れ端で呼ばれ続ける。受け取りをやめる。
            if chunk.isEmpty { handle.readabilityHandler = nil }
            lines.take(chunk)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            log.error("シェルを起動できなかった: \(error.localizedDescription, privacy: .public)")
            return .noAnswer(-1)
        }
        if let input {
            let handle = stdin.fileHandleForWriting
            // 書く前にシェルが終わっていると（rc ファイルのエラーなど）、読み手のいないパイプに書くことになり、
            // SIGPIPE で One ごと終わる（確かめた）。この記述子では SIGPIPE を出させず、書けなかったことだけを受け取る。
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? handle.write(contentsOf: Data(input.utf8))
        }

        _ = lines.done.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        // 標準入力を閉じると、app-server は自分から終わる。
        try? stdin.fileHandleForWriting.close()
        stop(process)

        if let state = lines.answer { return .answer(state) }
        return process.terminationStatus == 127 ? .notFound : .noAnswer(process.terminationStatus)
    }

    /// 自分から終わるのを2秒待ち、終わらなければ SIGTERM、それでも1秒で終わらなければ SIGKILL で止める。
    private static func stop(_ process: Process) {
        if waitForExit(process, seconds: 2) { return }
        process.terminate()
        if waitForExit(process, seconds: 1) { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        return !process.isRunning
    }

    /// その人のログインシェル（ディレクトリサービスに登録されたもの）。`-l -i -c` と `$0` `$@` の書き方が
    /// 通じる sh の仲間でなければ（fish など）、macOS の既定の zsh を使う。
    private static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return ["zsh", "bash", "sh", "ksh"].contains(name) ? path : "/bin/zsh"
    }
}

/// 標準出力の切れ端を行に分け、答えの行を探す。切れ端は別のスレッドから届くので、鍵をかけて触る。
private final class LineReader: @unchecked Sendable {
    /// 答えが見つかったか、出力が終わったか、行が長すぎてあきらめたら鳴る
    let done = DispatchSemaphore(value: 0)
    var answer: UsageLimits.State? { lock.withLock { found } }

    /// 1行の長さの上限。改行の無い出力が続いても、One のメモリを食いつぶさないように。
    /// Claude Code の出力でいちばん長い行（始めの、道具の一覧）が 44 KB だった。
    /// 見るのは切れ端を受け取ったあとなので、1つの切れ端のぶん（数十 KB）までは超えることがある。
    private static let maxLine = 8 << 20

    private let lock = NSLock()
    private let parse: (String) -> UsageLimits.State?
    private var buffer = Data()
    private var found: UsageLimits.State?
    private var finished = false

    init(answer parse: @escaping (String) -> UsageLimits.State?) {
        self.parse = parse
    }

    func take(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        // 空の切れ端は、出力が終わった印。最後の行に改行が無くても読む。
        guard !chunk.isEmpty else {
            if !buffer.isEmpty { found = parse(String(decoding: buffer, as: UTF8.self)) }
            finish()
            return
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let state = parse(line) {
                found = state
                finish()
                return
            }
        }
        if buffer.count > Self.maxLine { finish() }
    }

    private func finish() {
        finished = true
        buffer = Data()
        done.signal()
    }
}
