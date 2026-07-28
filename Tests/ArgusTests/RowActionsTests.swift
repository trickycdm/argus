import Foundation
import Testing
@testable import Argus

@MainActor
@Suite struct RowActionsTests {

    private func makeActions(store: SessionStore) -> RowActions {
        RowActions(store: store, notifier: Notifier())
    }

    @Test func linearURLResolution() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        let actions = makeActions(store: store)
        let session = store.session(id: "s1")!

        actions.config = ArgusConfig(editor: nil, linearWorkspace: "testws",
                                     board: nil, github: nil, projects: nil)
        session.gitBranch = "chore/eng-456-fix-thing"
        #expect(actions.linearURL(session)?.absoluteString == "https://linear.app/testws/issue/ENG-456",
                "linear: ticket id from branch, uppercased")

        session.gitBranch = "main"
        #expect(actions.linearURL(session) == nil, "linear: no ticket, no board → nil")

        actions.config = ArgusConfig(
            editor: nil, linearWorkspace: "testws", board: nil, github: nil,
            projects: [session.cwd: .init(board: "https://linear.app/testws/team/ENG/board", github: nil)])
        #expect(actions.linearURL(session)?.absoluteString == "https://linear.app/testws/team/ENG/board",
                "linear: board fallback from global projects")
    }

    @Test func snoozeSemantics() {
        let store = SessionStore()
        store.apply(event("SessionStart", "startup"))
        let actions = makeActions(store: store)
        let session = store.session(id: "s1")!

        #expect(!actions.isSnoozed(session), "snooze: off by default")
        actions.toggleSnooze(session)
        #expect(actions.isSnoozed(session), "snooze: on after toggle")
        actions.toggleSnooze(session)
        #expect(!actions.isSnoozed(session), "snooze: cleared on second toggle")
    }
}
