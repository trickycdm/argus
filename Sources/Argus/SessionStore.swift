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
    /// Sessions born as fork subagents. The global hooks fire in those
    /// processes too, but their rows read as duplicates of the session they
    /// were forked from. Events for these ids are dropped entirely.
    ///
    /// Membership is decided by the session's own SessionStart source, never
    /// by its parent process: the daemon's spare-pty pool (`claude bg-spare`)
    /// parents forks and human-driven sessions alike, so a claude parent says
    /// nothing about whether anyone is at the keyboard.
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
        // Sessions from the log may be long gone. Retire them on this single
        // check rather than granting the usual second opinion: the hysteresis
        // exists to absorb a transient kill(2) failure against a *live*
        // process, and waiting a sweep here would show every dead session in
        // the log as live for the first 15 seconds after launch.
        checkLiveness(retireOnFirstCheck: true)
        for session in live { onTranscriptRefresh?(session) }
        resort()
    }

    func apply(_ event: HookEvent, quiet: Bool = false) {
        guard !infraIDs.contains(event.sessionId) else { return }
        if byID[event.sessionId] == nil, Self.infraSessionStart(event) {
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
                session.ownerPid = Liveness.owningSessionPid(event.ppid)
            } else {
                // Recycled or vanished pid (log replay after the original
                // process died) — don't adopt it; with no pid, liveness
                // falls back to transcript staleness and retires the session.
                session.pid = nil
                session.pidStartTime = nil
                session.ownerPid = nil
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

    /// Pure: true if this event announces a fork subagent — the one kind of
    /// session nobody is driving, and the only one that says so, via
    /// `source == "fork"`. Every other source (`startup`, `resume`, `clear`,
    /// `compact`) belongs to a human, wherever its process was spawned.
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

    private func checkLiveness(retireOnFirstCheck: Bool = false) {
        let strikes = retireOnFirstCheck ? 1 : 2
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
                if session.deadChecks >= strikes {
                    // Stamp with last real activity, not detection time — on
                    // app relaunch old sessions die "now" but ended earlier.
                    setStatus(session, .dead, at: session.lastEventAt, quiet: false)
                }
            }
        }
        resort()
        pruneHistoryBeforeToday()
        countUntrackedProcesses()
        clearStaleShellTasks()
    }

    /// History is a "today" view, but replay reaches back a day so sessions
    /// that outlived midnight survive an app launch. The ones that didn't get
    /// retired by the liveness pass above, stamped with yesterday's last
    /// activity — drop those here, along with anything the app itself watched
    /// end before midnight while running through the night.
    private func pruneHistoryBeforeToday() {
        let midnight = Calendar.current.startOfDay(for: now)
        history.removeAll { session in
            guard let endedAt = session.endedAt, endedAt < midnight else { return false }
            // Forget the id too: a straggling event earns a fresh row rather
            // than resurrecting one the popover no longer lists.
            byID[session.id] = nil
            return true
        }
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

    /// Sorts by urgency, then re-seats each background agent immediately after
    /// the session that owns it. Agents don't compete for a slot of their own:
    /// a working agent sorting above the idle terminal it belongs to reads as
    /// two unrelated sessions in the same repo.
    private func resort() {
        let order: (Session, Session) -> Bool = {
            if $0.status.sortRank != $1.status.sortRank {
                return $0.status.sortRank < $1.status.sortRank
            }
            return $0.lastEventAt > $1.lastEventAt
        }
        var owners: [Int32: Session] = [:]
        for session in live where !session.isBackgroundAgent {
            if let pid = session.pid { owners[pid] = session }
        }
        var agents: [String: [Session]] = [:]
        var roots: [Session] = []
        for session in live {
            // An agent whose owner isn't tracked stands on its own — better a
            // row with no parent than a session Argus silently swallows.
            if session.isBackgroundAgent, let ownerPid = session.ownerPid,
               let owner = owners[ownerPid], owner.id != session.id {
                agents[owner.id, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        roots.sort(by: order)
        live = roots.flatMap { [$0] + (agents[$0.id]?.sorted(by: order) ?? []) }
    }

    /// The session a row is nested under, if its owner is on screen. Drives the
    /// row's indent — the view must not infer nesting from `isBackgroundAgent`
    /// alone, since an orphaned agent renders as a normal top-level row.
    func owner(of session: Session) -> Session? {
        guard session.isBackgroundAgent, let ownerPid = session.ownerPid else { return nil }
        return live.first { $0.pid == ownerPid && !$0.isBackgroundAgent && $0.id != session.id }
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
