import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private(set) var live: [Session] = []
    private(set) var history: [Session] = []
    /// Maintenance clock. Deliberately NOT observable: rows drive their
    /// elapsed labels from TimelineView, so the 1s tick doesn't re-render
    /// the whole tree (or anything at all while the popover is closed).
    @ObservationIgnored private(set) var now = Date()
    /// UUIDs of iTerm sessions currently open — refreshed when the popover
    /// appears; marks history rows whose terminal tab still exists. iTerm-only
    /// by design: Ghostty has no per-session identity that outlives the claude
    /// process, so its history rows always offer resume (see tabStillOpen).
    var openItermUUIDs: Set<String> = []
    /// Running claude processes Argus has no events for (started before the
    /// hooks were installed). Surfaced as a hint so the app is honest about
    /// what it can't see.
    private(set) var untrackedRunning = 0
    /// One-line operational alert (focus failed, malformed config) shown as
    /// an amber strip in the popover; auto-clears. NSLog covers the rest.
    private(set) var transientAlert: String?
    @ObservationIgnored private var alertClearWork: DispatchWorkItem?

    var needsYouCount: Int { live.filter { $0.status == .needsYou }.count }
    var readyCount: Int { live.filter { $0.status == .ready }.count }

    @ObservationIgnored var onTransition: ((Session, SessionStatus, SessionStatus) -> Void)?
    @ObservationIgnored var onTranscriptRefresh: ((Session) -> Void)?

    @ObservationIgnored private var byID: [String: Session] = [:]
    /// Sessions born inside agent infrastructure (fork subagents, daemon
    /// pools). The global hooks fire in those processes too, but they aren't
    /// user terminal sessions: their rows read as duplicates of the parent,
    /// they never fire SessionEnd, and their processes linger. Events for
    /// these ids are dropped entirely.
    @ObservationIgnored private var infraIDs: Set<String> = []
    @ObservationIgnored private var refreshWork: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var timer: Timer?

    static let stalledAfter: TimeInterval = 5 * 60
    /// A session sitting inside a tool call (last event PreToolUse) gets a
    /// much longer leash — long builds/tests fire no hook events while running.
    static let stalledAfterInTool: TimeInterval = 30 * 60
    static let livenessEvery = 15  // ticks

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    func session(id: String) -> Session? { byID[id] }

    func showAlert(_ message: String) {
        transientAlert = message
        alertClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.transientAlert = nil }
        alertClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Whether a history row's terminal tab is still open. A session that
    /// ended in iTerm but was resumed into Ghostty still carries its stale
    /// iTerm UUID — the terminal check keeps that from showing a false badge.
    func tabStillOpen(_ session: Session) -> Bool {
        guard session.terminal != .ghostty else { return false }
        return session.itermSessionUUID.map { openItermUUIDs.contains($0) } ?? false
    }

    /// Focusing a ready session means the user has seen the work — REVIEW
    /// drops to STBY so ready-counts always mean "unseen". Quiet: seeing it
    /// is not a transition worth notifying about.
    func acknowledge(_ session: Session) {
        guard session.status == .ready else { return }
        setStatus(session, .idle, at: now, quiet: true)
        resort()
    }

    func replay(_ events: [HookEvent]) {
        for event in events { apply(event, quiet: true) }
        checkLiveness()  // sessions from the log may be long gone
        for session in live { onTranscriptRefresh?(session) }
        resort()
    }

    func apply(_ event: HookEvent, quiet: Bool = false) {
        guard !infraIDs.contains(event.sessionId) else { return }
        // The live parent check only runs on a validated pid — a replayed,
        // recycled ppid can point at an unrelated claude-parented process
        // (an MCP server, say) and must not condemn a real session.
        if byID[event.sessionId] == nil,
           Self.infraSessionStart(event)
            || (Liveness.validatedStartTime(event.ppid, eventDate: event.date) != nil
                && Liveness.hasClaudeCLIParent(event.ppid)) {
            infraIDs.insert(event.sessionId)
            return
        }
        let session = byID[event.sessionId] ?? create(from: event)

        // Session ids are reused across resumes, and a resumed CLI can run
        // from a different directory — only SessionStart speaks for the cwd,
        // so a straggling event from the old process can't relabel the row.
        if !event.cwd.isEmpty && (session.cwd.isEmpty || event.event == "SessionStart") {
            session.cwd = event.cwd
        }
        if !event.transcript.isEmpty { session.transcriptPath = event.transcript }
        if event.ppid > 0 && event.ppid != session.pid {
            if let start = Liveness.validatedStartTime(event.ppid, eventDate: event.date) {
                session.pid = event.ppid
                session.pidStartTime = start
            } else {
                // Recycled or vanished pid (log replay after the original
                // process died) — don't adopt it; with no pid, liveness
                // falls back to transcript staleness and retires the session.
                session.pid = nil
                session.pidStartTime = nil
            }
        }
        if let uuid = ITermFocus.uuid(from: event.iterm) { session.itermSessionUUID = uuid }
        // Only overwrite on positive detection — a v1 log line replayed after
        // a v2 one must not reset a known terminal to unknown.
        if let terminal = TerminalApp.detect(itermID: event.iterm, termProgram: event.term) {
            session.terminal = terminal
        }
        session.lastEventAt = event.date
        session.lastEventName = event.event
        session.deadChecks = 0

        switch event.event {
        case "UserPromptSubmit": session.toolUsesThisTurn = 0
        case "PreToolUse", "PostToolUse": session.toolUsesThisTurn += 1
        default: break
        }

        if let target = Self.targetStatus(for: event,
                                          toolUsesThisTurn: session.toolUsesThisTurn) {
            setStatus(session, target, at: event.date, quiet: quiet)
        }
        if !quiet {
            scheduleTranscriptRefresh(session)
            resort()
        }
    }

    // MARK: - State machine

    static func targetStatus(for event: HookEvent,
                             toolUsesThisTurn: Int) -> SessionStatus? {
        switch event.event {
        case "SessionStart":
            // After startup/resume/clear the CLI sits at the prompt — that's
            // idle, not working. Compaction fires SessionStart mid-turn.
            return event.detail == "compact" ? .working : .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "Notification":
            // Unrecognized notifications leave the status alone — turn ends
            // arrive as Stop, so guessing .idle here would only downgrade a
            // ready session.
            return notificationNeedsYou(event.detail) ? .needsYou : nil
        case "Stop":
            // A turn that used tools produced something to look at; a bare
            // Q&A turn just returns to the prompt.
            return toolUsesThisTurn > 0 ? .ready : .idle
        case "SessionEnd":
            return .ended
        default:
            return nil
        }
    }

    /// Pure: true if this event announces an agent-infrastructure session by
    /// its own start record. Forks declare themselves (`source == "fork"`);
    /// other infrastructure is caught by the live parent-process check
    /// (`Liveness.hasClaudeCLIParent`), which this complements during replay
    /// when the process is already gone.
    static func infraSessionStart(_ event: HookEvent) -> Bool {
        event.event == "SessionStart" && event.detail == "fork"
    }

    /// The hook forwards notification_type when present, else the free-text
    /// message — match both, since notification_type is not guaranteed across
    /// CLI versions.
    static func notificationNeedsYou(_ detail: String) -> Bool {
        switch detail {
        case "permission_prompt", "elicitation_dialog", "agent_needs_input":
            return true
        default:
            let text = detail.lowercased()
            return text.contains("permission") || text.contains("needs your input")
                || text.contains("waiting for your input")
        }
    }

    private func create(from event: HookEvent) -> Session {
        let session = Session(id: event.sessionId, cwd: event.cwd,
                              status: .working, at: event.date)
        byID[event.sessionId] = session
        live.append(session)
        return session
    }

    private func setStatus(_ session: Session, _ target: SessionStatus,
                           at date: Date, quiet: Bool) {
        let old = session.status
        guard old != target else { return }

        // A live event for an ended/dead session resurrects it (e.g. resumed
        // session, or SessionEnd never fired and events keep coming). Must
        // stay behind the guard: a repeated .dead/.ended must not drag the
        // session back into the live list.
        if (old == .ended || old == .dead) && target != .ended {
            history.removeAll { $0.id == session.id }
            if !live.contains(where: { $0.id == session.id }) { live.append(session) }
            session.endedAt = nil
        }
        session.status = target
        session.statusSince = date

        if target == .ended || target == .dead {
            session.endedAt = date
            // Background tasks are children of the claude process — they died
            // with it. (A resume rewrites the transcript, which resets and
            // replays these sets anyway.)
            session.openShellTasks = []
            session.openAgentTasks = []
            live.removeAll { $0.id == session.id }
            if !history.contains(where: { $0.id == session.id }) {
                history.insert(session, at: 0)
                // The log is daily, so history resets at midnight anyway —
                // the cap only guards against a pathological day.
                if history.count > 50 { history.removeLast(history.count - 50) }
            }
        }
        if !quiet {
            onTransition?(session, old, target)
        }
    }

    // MARK: - Timer

    private func tick() {
        now = Date()
        tickCount += 1

        for session in live where session.status == .working {
            let threshold = session.lastEventName == "PreToolUse"
                ? Self.stalledAfterInTool : Self.stalledAfter
            if now.timeIntervalSince(session.lastEventAt) > threshold,
               !Liveness.transcriptActive(session.transcriptPath,
                                          within: threshold, now: now) {
                setStatus(session, .stalled, at: now, quiet: false)
            }
        }
        if tickCount % Self.livenessEvery == 0 {
            checkLiveness()
        }
    }

    private func checkLiveness() {
        for session in live {
            let alive: Bool
            if let pid = session.pid {
                alive = Liveness.isAlive(pid, startedAt: session.pidStartTime)
            } else {
                alive = !Liveness.transcriptStale(session.transcriptPath,
                                                  lastEventAt: session.lastEventAt)
            }
            if alive {
                session.deadChecks = 0
            } else {
                session.deadChecks += 1
                if session.deadChecks >= 2 {
                    // Stamp with last real activity, not detection time — on
                    // app relaunch old sessions die "now" but ended earlier.
                    setStatus(session, .dead, at: session.lastEventAt, quiet: false)
                }
            }
        }
        resort()
        countUntrackedProcesses()
        clearStaleShellTasks()
    }

    /// A background shell *is* its task: the session's claude pid holding
    /// zero live shell children while not working means the tasks finished,
    /// even when their completion notification landed in another transcript
    /// (observed with fork agents) and the badge would otherwise stick.
    private func clearStaleShellTasks() {
        let candidates = live
            .filter { $0.status != .working && !$0.openShellTasks.isEmpty }
            .compactMap { session in session.pid.map { (id: session.id, pid: $0) } }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) {
            let stale = candidates
                .filter { Liveness.shellChildCount(of: $0.pid) == 0 }
                .map(\.id)
            guard !stale.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for id in stale {
                    guard let session = self.byID[id], session.status != .working,
                          !session.openShellTasks.isEmpty else { continue }
                    NSLog("Argus: clearing \(session.openShellTasks.count) background shell task(s) for session \(id) — no live shell children")
                    session.openShellTasks = []
                }
            }
        }
    }

    /// Compares running Claude CLI processes against every pid Argus has ever
    /// associated with a session — live *and* history — so a session that
    /// merely changed state doesn't make its own process look untracked.
    private func countUntrackedProcesses() {
        let trackedPids = Set((live + history).compactMap(\.pid))
        Task.detached(priority: .utility) {
            let count = Liveness.claudeCLIPids().subtracting(trackedPids).count
            await MainActor.run { [weak self] in
                self?.untrackedRunning = count
            }
        }
    }

    // MARK: - Helpers

    private func resort() {
        live.sort {
            if $0.status.sortRank != $1.status.sortRank {
                return $0.status.sortRank < $1.status.sortRank
            }
            return $0.lastEventAt > $1.lastEventAt
        }
    }

    private func scheduleTranscriptRefresh(_ session: Session) {
        refreshWork[session.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.refreshWork[session.id] = nil
            self.onTranscriptRefresh?(session)
        }
        refreshWork[session.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
