import Foundation
import Observation

enum SessionStatus: String {
    /// Conversation states: working, needsYou (blocked on user input),
    /// ready (turn finished after doing real work — review it), idle (at the
    /// prompt, nothing pending), stalled (working but silent too long).
    /// Liveness states: dead (process gone without cleanup), ended (clean exit).
    case working, needsYou, ready, idle, stalled, dead, ended

    var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .ready: return 1
        case .working: return 2
        case .stalled: return 3
        case .idle: return 4
        case .dead: return 5
        case .ended: return 6
        }
    }
}

/// One line of the Argus event log, as written by hooks/argus-hook.sh.
struct HookEvent: Decodable {
    let v: Int
    let ts: Int
    let event: String
    let detail: String
    let sessionId: String
    let cwd: String
    let transcript: String
    let iterm: String
    /// Raw TERM_PROGRAM at hook time (v2+) — optional so v1 lines decode.
    let term: String?
    let ppid: Int32

    enum CodingKeys: String, CodingKey {
        case v, ts, event, detail
        case sessionId = "session_id"
        case cwd, transcript, iterm, term, ppid
    }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

struct TokenTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }
}

@Observable
final class Session: Identifiable {
    let id: String
    var cwd: String
    var gitBranch: String?
    var itermSessionUUID: String?
    var pid: Int32?
    /// Kernel start time of `pid`, captured when first seen — liveness checks
    /// compare against it to detect pid reuse without trusting process names.
    var pidStartTime: UInt64?
    var transcriptPath: String?
    /// Host terminal, detected from hook data; nil = unknown (old logs or an
    /// unsupported terminal) — flows fall back to the config default.
    var terminal: TerminalApp?
    var status: SessionStatus
    var statusSince: Date
    var lastEventAt: Date
    var lastAssistantLine: String?
    var tokens = TokenTotals()
    var model: String?
    var costUSD: Double?
    var transcriptOffset: UInt64 = 0
    /// Prompt size of the latest main-chain assistant message (input + cache
    /// read + cache write) — approximates current context-window occupancy.
    var contextTokens: Int?
    /// Edge-trigger latch for the ≥65% context alarm; resets below 60%.
    var contextAlerted = false
    /// Working-tree state shown as the row's git chip; nil when cwd isn't a
    /// repo (or not fetched yet).
    var gitState: GitState?
    @ObservationIgnored var gitStateFetchedAt: Date?
    /// Notifications for this session are suppressed until this instant.
    var snoozedUntil: Date?
    var endedAt: Date?
    var deadChecks = 0
    /// Tool uses since the last UserPromptSubmit — decides whether Stop means
    /// "ready for review" (did work) or merely "idle" (trivial turn).
    var toolUsesThisTurn = 0
    /// Ids of background Bash shells this session launched whose completion
    /// notification hasn't appeared in its transcript yet — a turn can end
    /// while these still run. Cross-checked against live shell child
    /// processes by the liveness sweep, because completions can be delivered
    /// to another transcript (observed with fork agents) and never arrive.
    var openShellTasks: Set<String> = []
    /// Ids of background agents this session launched, same lifecycle as
    /// `openShellTasks` but with no child process to cross-check against.
    var openAgentTasks: Set<String> = []
    /// Drives the row's BG chip and the turn-end notification suffix.
    var openBackgroundTaskCount: Int { openShellTasks.count + openAgentTasks.count }
    /// Last hook event name — a session whose last event is PreToolUse is
    /// inside a tool call, which can legitimately be silent for a long time.
    var lastEventName = ""

    var projectName: String { (cwd as NSString).lastPathComponent }

    /// Context occupancy 0…1, or nil before any usage data arrives.
    var contextFraction: Double? {
        guard let contextTokens else { return nil }
        return min(1.0, Double(contextTokens) / Double(Self.contextWindow(for: model)))
    }

    /// Context alarm threshold (fraction). Configurable via `contextAlarm`
    /// (percent) in ~/.config/argus/config.json; applied on launch and
    /// popover open. Main-actor: only views and Notifier touch it.
    @MainActor static var contextAlarmAt = Double(ContextAlarm.defaultPercent) / 100

    static func contextWindow(for model: String?) -> Int {
        ModelCatalog.entry(for: model)?.contextWindow ?? ModelCatalog.defaultContextWindow
    }

    init(id: String, cwd: String, status: SessionStatus, at date: Date) {
        self.id = id
        self.cwd = cwd
        self.status = status
        self.statusSince = date
        self.lastEventAt = date
    }
}
