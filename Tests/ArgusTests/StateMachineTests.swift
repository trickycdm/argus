import Foundation
import Testing
@testable import Argus

@MainActor
@Suite struct StateMachineTests {

    @Test func toolTurnEndsReadyBareTurnEndsIdle() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        #expect(store.live.first?.status == .idle, "session start → idle at prompt")
        store.apply(event("UserPromptSubmit"))
        store.apply(event("PreToolUse"))
        store.apply(event("PostToolUse"))
        store.apply(event("Stop"))
        #expect(store.live.first?.status == .ready, "tool-using turn → ready")

        store.apply(event("UserPromptSubmit"))
        #expect(store.live.first?.status == .working, "new prompt → working")
        store.apply(event("Stop"))
        #expect(store.live.first?.status == .idle, "bare Q&A turn → idle")
    }

    @Test func notificationClassification() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        store.apply(event("Notification", "permission_prompt"))
        #expect(store.live.first?.status == .needsYou, "permission_prompt → needsYou")
        store.apply(event("UserPromptSubmit"))
        store.apply(event("PreToolUse"))
        store.apply(event("Notification", "Claude needs your permission to use Bash"))
        #expect(store.live.first?.status == .needsYou, "message-text fallback → needsYou")
        store.apply(event("PostToolUse"))
        store.apply(event("Stop"))
        store.apply(event("Notification", "some unknown thing"))
        #expect(store.live.first?.status == .ready, "unknown notification leaves ready alone")
    }

    @Test func cwdOnlyTrustedFromSessionStart() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        store.apply(event("PostToolUse", cwd: "/tmp/other"))
        #expect(store.live.first?.cwd == "/tmp/proj", "non-start event can't change cwd")
    }

    @Test func sessionEndAndResume() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        store.apply(event("SessionEnd", "other"))
        #expect(store.live.isEmpty && store.history.count == 1, "SessionEnd → history")
        store.apply(event("SessionStart", "resume", cwd: "/tmp/resumed"))
        #expect(store.live.first?.status == .idle, "resume resurrects to idle at prompt")
        #expect(store.live.first?.cwd == "/tmp/resumed", "SessionStart updates cwd")
    }

    @Test func forkSessionsAreNeverTracked() {
        let store = SessionStore()
        store.apply(event("SessionStart", "fork", sid: "fork1"))
        #expect(store.live.isEmpty && store.history.isEmpty,
                "a fork-born session is agent infrastructure, not a row")
        store.apply(event("UserPromptSubmit", sid: "fork1"))
        store.apply(event("Stop", sid: "fork1"))
        #expect(store.live.isEmpty,
                "later events for a fork session stay dropped")
        store.apply(event("SessionStart", "startup", sid: "real1"))
        #expect(store.live.count == 1,
                "a normal session in the same store still tracks")
    }

    /// The daemon's spare-pty pool parents forks and human-driven sessions
    /// from the same pid, so only the declared source can tell them apart.
    @Test func daemonHostedSessionsTrackDespiteAClaudeParent() {
        let store = SessionStore()
        let pool = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Int(Date().timeIntervalSince1970)
        store.apply(event("SessionStart", "fork", sid: "fork1", ppid: pool, ts: now))
        #expect(store.live.isEmpty, "a fork from the pool is still dropped")

        store.apply(event("SessionStart", "clear", sid: "user1", ppid: pool, ts: now))
        store.apply(event("Notification", "permission_prompt", sid: "user1",
                          ppid: pool, ts: now))
        #expect(store.live.count == 1, "a cleared session sharing that parent is a row")
        #expect(store.live.first?.status == .needsYou,
                "and its permission prompt reaches the user")
    }

    /// A working background agent must not outrank the idle terminal that owns
    /// it — side by side at top level they read as two sessions in one repo.
    @Test func backgroundAgentNestsUnderItsOwningSession() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup", sid: "term"))
        store.apply(event("SessionStart", "clear", sid: "agent"))
        store.apply(event("UserPromptSubmit", sid: "agent"))

        guard let term = store.session(id: "term"),
              let agent = store.session(id: "agent") else {
            Issue.record("both sessions should be tracked"); return
        }
        #expect(term.status == .idle && agent.status == .working,
                "idle owner, working agent — the order a flat sort gets wrong")
        // Stand in for the process walk: the agent runs in the daemon pool
        // (71502) whose ancestry roots at the terminal's own pid (13122).
        term.pid = 13122
        term.ownerPid = 13122
        agent.pid = 71502
        agent.ownerPid = 13122
        store.apply(event("PostToolUse", sid: "agent"))  // triggers a resort

        #expect(store.live.map(\.id) == ["term", "agent"],
                "the agent is seated under its owner, not sorted above it")
        #expect(store.owner(of: agent)?.id == "term", "and the view can name that owner")
        #expect(store.owner(of: term) == nil, "a terminal session is never nested")
        #expect(agent.isBackgroundAgent && !term.isBackgroundAgent,
                "only the pool-hosted session is an agent")
    }

    @Test func orphanedBackgroundAgentStaysATopLevelRow() {
        let store = SessionStore()
        store.apply(event("SessionStart", "clear", sid: "agent"))
        guard let agent = store.session(id: "agent") else {
            Issue.record("session should be tracked"); return
        }
        agent.pid = 71502
        agent.ownerPid = 13122  // owner never emitted events — not tracked
        store.apply(event("UserPromptSubmit", sid: "agent"))

        #expect(store.live.map(\.id) == ["agent"], "it still gets a row")
        #expect(store.owner(of: agent) == nil, "with no owner to nest under")
    }

    @Test func historyKeepsOnlyTodaysEndedSessions() {
        let store = SessionStore()
        let midnight = Calendar.current.startOfDay(for: Date())
        let lastNight = Int(midnight.timeIntervalSince1970) - 3600
        let thisMorning = Int(midnight.timeIntervalSince1970) + 3600

        store.replay([
            event("SessionStart", "startup", sid: "yesterday", ts: lastNight),
            event("SessionEnd", "other", sid: "yesterday", ts: lastNight),
            event("SessionStart", "startup", sid: "today", ts: thisMorning),
            event("SessionEnd", "other", sid: "today", ts: thisMorning),
        ])
        #expect(store.history.map(\.id) == ["today"],
                "replay reaches back a day, but history stays a today view")
        #expect(store.session(id: "yesterday") == nil,
                "the pruned session's id is forgotten too")
    }

    @Test func infraSessionStartClassification() {
        #expect(SessionStore.infraSessionStart(event("SessionStart", "fork")),
                "SessionStart with source fork is infrastructure")
        #expect(!SessionStore.infraSessionStart(event("SessionStart", "startup")),
                "a normal startup is not infrastructure")
        #expect(!SessionStore.infraSessionStart(event("SessionStart", "resume")),
                "resume is a user action — Argus's own resume flow depends on it")
        #expect(!SessionStore.infraSessionStart(event("Stop", "fork")),
                "only SessionStart speaks for the session's origin")
    }

    @Test func repeatedTerminalStatusStaysInHistory() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        store.apply(event("SessionEnd", "other"))
        let endedAt = store.history.first?.endedAt
        store.apply(event("SessionEnd", "other"))
        #expect(store.live.isEmpty && store.history.count == 1,
                "repeated SessionEnd must not resurrect into the live list")
        #expect(store.history.first?.endedAt == endedAt, "endedAt survives the repeat")
    }

    @Test func countsAndSortOrder() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        store.apply(event("Notification", "agent_needs_input"))
        store.apply(event("UserPromptSubmit", sid: "s2"))
        store.apply(event("PreToolUse", sid: "s2"))
        store.apply(event("Stop", sid: "s2"))
        #expect(store.needsYouCount == 1 && store.readyCount == 1, "counts: 1 blocked, 1 ready")
        #expect(store.live.first?.id == "s1", "blocked sorts above ready")
    }

    @Test func terminalDetectionSurvivesOldLogLines() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup", iterm: "", term: "ghostty"))
        #expect(store.live.first?.terminal == .ghostty, "TERM_PROGRAM=ghostty → ghostty")
        store.apply(event("PostToolUse", iterm: "", term: nil))
        #expect(store.live.first?.terminal == .ghostty,
                "v1-shaped event must not reset a detected terminal")
    }

    @Test func tabStillOpenIsITermOnly() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))   // default iterm uuid AAA
        store.apply(event("SessionStart", "startup", sid: "s2", iterm: "", term: "ghostty"))
        store.openItermUUIDs = ["AAA"]
        #expect(store.tabStillOpen(store.session(id: "s1")!),
                "iTerm session with its uuid in the open set → badge")
        #expect(!store.tabStillOpen(store.session(id: "s2")!),
                "ghostty session never badges — no probeable identity")

        // Ended in iTerm, resumed into Ghostty: the stale iTerm uuid survives
        // on the session but must not produce a false badge.
        store.apply(event("SessionEnd", "other"))
        store.apply(event("SessionStart", "resume", iterm: "", term: "ghostty"))
        #expect(store.session(id: "s1")?.terminal == .ghostty, "resume re-detects")
        #expect(!store.tabStillOpen(store.session(id: "s1")!),
                "stale iTerm uuid on a ghostty session must not badge")
    }

    @Test func acknowledgeOnlyDowngradesReady() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        let session = store.session(id: "s1")!
        session.status = .working
        store.acknowledge(session)
        #expect(session.status == .working, "acknowledge: working untouched")
        session.status = .ready
        store.acknowledge(session)
        #expect(session.status == .idle, "acknowledge: ready → idle")
    }
}
