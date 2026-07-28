import SwiftUI

/// Owns and wires the long-lived components. Created once by the App struct,
/// which also guarantees the notification delegate (inside Notifier) is
/// installed before app launch finishes — required for cold-launch taps.
@MainActor
final class ArgusController {
    let store = SessionStore()
    let tailer = EventLogTailer()
    let transcripts = TranscriptReader()
    let notifier = Notifier()
    let actions: RowActions

    init() {
        actions = RowActions(store: store, notifier: notifier)
        Self.applyConfig(actions.config)
        tailer.onReplay = { [store] events in store.replay(events) }
        tailer.onEvent = { [store] event in store.apply(event) }
        store.onTranscriptRefresh = { [transcripts, notifier] session in
            // The context check must see the freshly-applied usage numbers,
            // so it rides the refresh completion.
            transcripts.refresh(session) { notifier.checkContext(session) }
        }
        store.onTransition = { [notifier] session, old, new in
            notifier.transition(session, from: old, to: new)
        }
        notifier.onNotificationTap = { [weak self] id in
            guard let self, let session = self.store.session(id: id) else { return }
            self.store.acknowledge(session)
            self.focusOrResume(session)
        }
        store.start()
        tailer.start()
    }

    func focus(_ session: Session) {
        store.acknowledge(session)   // focusing a ready session = reviewed
        ITermFocus.focus(session) { [store] result in
            if case .error(let message) = result {
                NSLog("Argus: focus failed — \(message)")
                store.showAlert("Focus failed — \(message)")
            }
        }
    }

    /// Settings that live outside the actions object. Clamped so a config
    /// typo can't make the alarm unreachable or constantly firing.
    private static func applyConfig(_ config: ArgusConfig) {
        let percent = (config.contextAlarm ?? ContextAlarm.defaultPercent)
            .clamped(to: ContextAlarm.clampPercent)
        Session.contextAlarmAt = Double(percent) / 100
    }

    /// History rows: focus the tab if it still exists, otherwise reopen the
    /// session in a new iTerm tab via `claude --resume`.
    func focusOrResume(_ session: Session) {
        ITermFocus.focus(session) { [store] result in
            switch result {
            case .focused:
                break
            case .notFound, .noUUID:
                // The session re-materializes via SessionStart on resume.
                ITermFocus.resume(session) { resumeResult in
                    if case .error(let message) = resumeResult {
                        NSLog("Argus: resume failed — \(message)")
                        store.showAlert("Resume failed — \(message)")
                    }
                }
            case .error(let message):
                NSLog("Argus: focus failed — \(message)")
                store.showAlert("Focus failed — \(message)")
            }
        }
    }

    /// Called when the popover appears: marks history rows whose tab is
    /// open, re-reads config, and refreshes git chips for live sessions.
    func refreshOnPopoverOpen() {
        ITermFocus.listOpenSessionUUIDs { [store] uuids in
            store.openItermUUIDs = uuids
        }
        actions.config = ArgusConfig.loadGlobal()
        Self.applyConfig(actions.config)
        if ArgusConfig.globalLoadError() != nil {
            store.showAlert("Config malformed — check ~/.config/argus/config.json")
        }
        for session in store.live {
            let stale = session.gitStateFetchedAt
                .map { Date().timeIntervalSince($0) > 15 } ?? true
            guard stale else { continue }
            session.gitStateFetchedAt = Date()   // set before await = in-flight guard
            Task { session.gitState = await GitStatus.fetch(cwd: session.cwd) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct ArgusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = ArgusController()

    var body: some Scene {
        MenuBarExtra {
            SessionListView(
                store: controller.store,
                actions: controller.actions,
                focus: { controller.focus($0) },
                focusOrResume: { controller.focusOrResume($0) },
                onAppearRefresh: { controller.refreshOnPopoverOpen() }
            )
        } label: {
            MenuBarLabel(needsYouCount: controller.store.needsYouCount,
                         readyCount: controller.store.readyCount)
        }
        .menuBarExtraStyle(.window)
    }
}
