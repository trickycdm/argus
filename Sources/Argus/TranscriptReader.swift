import Foundation

/// Incrementally parses a session's Claude Code transcript (JSONL) to extract
/// the last assistant message, accumulated token usage, model, and git branch.
/// Keeps a per-session byte-offset cursor so each refresh reads only new
/// bytes. File I/O and decoding run off the main actor; only the apply step
/// touches the session — launch replay no longer blocks the UI.
@MainActor
final class TranscriptReader {
    /// Per-session task chain: refreshes for one session run strictly in
    /// order, so the byte-offset cursor can never be read by one refresh
    /// while another is still advancing it.
    private var chains: [String: Task<Void, Never>] = [:]

    func refresh(_ session: Session, then completion: (() -> Void)? = nil) {
        guard let path = session.transcriptPath else { return }
        let previous = chains[session.id]
        chains[session.id] = Task { [weak session] in
            await previous?.value
            guard let session else { return }
            let offset = session.transcriptOffset
            let result = await Task.detached(priority: .utility) {
                Self.parse(path: path, from: offset)
            }.value
            if let result { Self.apply(result, to: session) }
            completion?()
        }
    }

    /// Everything the session needs from one incremental read, produced
    /// off-actor and applied on the main actor in one step.
    struct ParseResult {
        var newOffset: UInt64
        var didReset = false
        var tokensDelta = TokenTotals()
        var model: String?
        var gitBranch: String?
        var lastAssistantLine: String?
        var contextTokens: Int?
        /// Background tasks launched / completed in this read, by id. Applied
        /// union-then-subtract, so a task that launches and completes within
        /// one read nets to closed. Shells and agents are tracked apart: only
        /// shells can be liveness-checked against child processes.
        var openedShellTasks: Set<String> = []
        var openedAgentTasks: Set<String> = []
        var closedTasks: Set<String> = []
    }

    nonisolated static func parse(path: String, from startOffset: UInt64) -> ParseResult? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var offset = startOffset
        var result = ParseResult(newOffset: startOffset)
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Transcript rewritten (resume/compaction) — start over.
            offset = 0
            result.didReset = true
        }
        guard size > offset else { return result.didReset ? result : nil }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              // Consume only complete lines; leave a trailing partial for next time.
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return result.didReset ? result : nil
        }
        let complete = data[data.startIndex...lastNewline]
        result.newOffset = offset + UInt64(complete.count)

        let decoder = JSONDecoder()
        var searchStart = complete.startIndex
        while searchStart < complete.endIndex {
            let lineEnd = complete[searchStart...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[searchStart..<lineEnd]
            searchStart = lineEnd < complete.endIndex ? complete.index(after: lineEnd) : complete.endIndex
            guard !line.isEmpty else { continue }
            process(Data(line), decoder: decoder, into: &result)
        }
        return result
    }

    private nonisolated static func process(_ line: Data, decoder: JSONDecoder,
                                            into result: inout ParseResult) {
        // Background-task markers ride non-assistant lines; usage/content
        // rides assistant lines. The split doubles as a safety gate: assistant
        // lines can quote receipts and notification tags verbatim (tool
        // inputs, echoed output) and must never open or close a task.
        guard line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil else {
            processTaskMarkers(line, decoder: decoder, into: &result)
            return
        }
        // Cheap pre-filter before JSON decoding: only assistant lines carry
        // usage/content we need (they also carry gitBranch).
        guard let entry = try? decoder.decode(TranscriptLine.self, from: line),
              entry.type == "assistant" else { return }

        if let branch = entry.gitBranch, !branch.isEmpty {
            result.gitBranch = branch
        }
        guard let message = entry.message else { return }
        if let model = message.model {
            result.model = model
        }
        if let usage = message.usage {
            result.tokensDelta.input += usage.inputTokens ?? 0
            result.tokensDelta.output += usage.outputTokens ?? 0
            result.tokensDelta.cacheRead += usage.cacheReadInputTokens ?? 0
            result.tokensDelta.cacheWrite += usage.cacheCreationInputTokens ?? 0
            // Context occupancy = the request's full prompt size. Sidechain
            // (subagent) messages have their own context — skip them.
            if entry.isSidechain != true {
                result.contextTokens = (usage.inputTokens ?? 0)
                    + (usage.cacheReadInputTokens ?? 0)
                    + (usage.cacheCreationInputTokens ?? 0)
            }
        }
        if case .blocks(let blocks)? = message.content {
            let lastText = blocks.last(where: { $0.type == "text" && !($0.text ?? "").isEmpty })
            if let text = lastText?.text {
                result.lastAssistantLine = oneLine(text)
            }
        } else if case .text(let text)? = message.content, !text.isEmpty {
            result.lastAssistantLine = oneLine(text)
        }
    }

    /// Background-task lifecycle on non-assistant lines. Opens come only from
    /// structured receipt fields — never from matching content text, which can
    /// quote the same strings. Closes come from task-notification tags; their
    /// delivery record varies by CLI version (user / queue-operation /
    /// attachment lines), so the tags are matched on the raw line. Ids only —
    /// task prompts and output never leave the parser.
    private nonisolated static func processTaskMarkers(_ line: Data, decoder: JSONDecoder,
                                                       into result: inout ParseResult) {
        let mayOpen = line.range(of: Data("\"backgroundTaskId\"".utf8)) != nil
            || line.range(of: Data("\"async_launched\"".utf8)) != nil
        if mayOpen,
           let entry = try? decoder.decode(TaskReceiptLine.self, from: line),
           // Sidechain lines belong to a subagent's own run — its tasks
           // complete before the subagent reports, so don't badge them.
           entry.isSidechain != true,
           let receipt = entry.toolUseResult {
            if let id = receipt.backgroundTaskId {
                result.openedShellTasks.insert(id)
            }
            if receipt.status == "async_launched", let id = receipt.agentId {
                result.openedAgentTasks.insert(id)
            }
        }
        if line.range(of: Data("<task-notification>".utf8)) != nil {
            let text = String(decoding: line, as: UTF8.self)
            result.closedTasks.formUnion(taskNotificationIds(text))
        }
    }

    /// Pure: every id named by a `<task-id>…</task-id>` tag in a raw
    /// transcript line. Ids are validated to the observed shape (short
    /// [A-Za-z0-9_-] tokens) so quoted or mangled tags can't inject noise.
    nonisolated static func taskNotificationIds(_ line: String) -> [String] {
        var ids: [String] = []
        var search = line.startIndex
        while let open = line.range(of: "<task-id>", range: search..<line.endIndex),
              let close = line.range(of: "</task-id>", range: open.upperBound..<line.endIndex) {
            let id = String(line[open.upperBound..<close.lowerBound])
            if !id.isEmpty, id.count <= 64,
               id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                ids.append(id)
            }
            search = close.upperBound
        }
        return ids
    }

    private static func apply(_ result: ParseResult, to session: Session) {
        if result.didReset {
            session.tokens = TokenTotals()
            session.contextTokens = nil
            session.openShellTasks = []
            session.openAgentTasks = []
        }
        session.transcriptOffset = result.newOffset
        session.tokens.input += result.tokensDelta.input
        session.tokens.output += result.tokensDelta.output
        session.tokens.cacheRead += result.tokensDelta.cacheRead
        session.tokens.cacheWrite += result.tokensDelta.cacheWrite
        if let model = result.model { session.model = model }
        if let branch = result.gitBranch { session.gitBranch = branch }
        if let line = result.lastAssistantLine { session.lastAssistantLine = line }
        if let context = result.contextTokens { session.contextTokens = context }
        session.openShellTasks.formUnion(result.openedShellTasks)
        session.openShellTasks.subtract(result.closedTasks)
        session.openAgentTasks.formUnion(result.openedAgentTasks)
        session.openAgentTasks.subtract(result.closedTasks)
        session.costUSD = Pricing.estimate(model: session.model, tokens: session.tokens)
    }

    nonisolated static func oneLine(_ text: String, limit: Int = 120) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}

// MARK: - Transcript line schema (only the fields we read)

/// A tool-result line that may carry a background-task launch receipt.
/// `toolUseResult` is heterogeneous across tools (object, string, or array) —
/// a decode failure just means "not a receipt", never an error.
private struct TaskReceiptLine: Decodable {
    let isSidechain: Bool?
    let toolUseResult: ToolUseResult?

    struct ToolUseResult: Decodable {
        /// Background Bash receipt ("Command running in background with ID …").
        let backgroundTaskId: String?
        /// Background agent receipt, paired with status "async_launched".
        let agentId: String?
        let status: String?
    }
}

private struct TranscriptLine: Decodable {
    let type: String?
    let gitBranch: String?
    let isSidechain: Bool?
    let message: Message?

    struct Message: Decodable {
        let model: String?
        let content: Content?
        let usage: Usage?
    }

    enum Content: Decodable {
        case text(String)
        case blocks([Block])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([Block].self))
            }
        }
    }

    struct Block: Decodable {
        let type: String?
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }
}

// MARK: - Cost estimation

enum Pricing {
    static func estimate(model: String?, tokens: TokenTotals) -> Double? {
        guard let rates = ModelCatalog.entry(for: model) else { return nil }
        let millions = { (count: Int) in Double(count) / 1_000_000 }
        return millions(tokens.input) * rates.input
            + millions(tokens.output) * rates.output
            + millions(tokens.cacheRead) * rates.cacheRead
            + millions(tokens.cacheWrite) * rates.cacheWrite
    }
}
