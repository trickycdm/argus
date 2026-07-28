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
