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
