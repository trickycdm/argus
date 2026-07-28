import SwiftUI
import AppKit

/// Everything a session row can do beyond focusing its tab. One object owned
/// by ArgusController and injected as a single parameter so view signatures
/// stay small. Config is re-read by the controller on popover open.
@MainActor
final class RowActions {
    var config = ArgusConfig.loadGlobal()
    let store: SessionStore
    let notifier: Notifier

    init(store: SessionStore, notifier: Notifier) {
        self.store = store
        self.notifier = notifier
    }

    /// `open -a <name> <dir>`: LaunchServices resolves the app by name and
    /// returns immediately — the by-name NSWorkspace API is deprecated.
    func openEditor(_ session: Session) {
        let editor = config.resolved(for: session.cwd).editor
        Task { _ = await Subprocess.run("/usr/bin/open", ["-a", editor, session.cwd]) }
    }

    func openGitHub(_ session: Session) {
        let resolved = config.resolved(for: session.cwd)
        Task {
            if let override = resolved.github, let url = URL(string: override) {
                NSWorkspace.shared.open(url)
                return
            }
            let result = await Subprocess.run(
                "/usr/bin/git", ["-C", session.cwd, "remote", "get-url", "origin"])
            guard result.status == 0,
                  let url = GitStatus.webURL(remote: result.stdout, branch: session.gitBranch) else {
                NSLog("Argus: no browsable remote for \(session.projectName)")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// Ticket id in the branch name (feat/ENG-123-x) deep-links the issue;
    /// otherwise the configured board. nil = nothing to link (menu disables).
    func linearURL(_ session: Session) -> URL? {
        let resolved = config.resolved(for: session.cwd)
        if let workspace = resolved.linearWorkspace?
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let branch = session.gitBranch,
           let range = branch.range(of: #"[A-Za-z][A-Za-z0-9]+-\d+"#,
                                    options: .regularExpression) {
            return URL(string: "https://linear.app/\(workspace)/issue/\(branch[range].uppercased())")
        }
        return resolved.board.flatMap(URL.init(string:))
    }

    func openLinear(_ session: Session) {
        if let url = linearURL(session) { NSWorkspace.shared.open(url) }
    }

    func copySessionId(_ session: Session) {
        copy(session.id)
    }

    func copyResumeCommand(_ session: Session) {
        copy("claude --resume \(session.id)")
    }

    func markReviewed(_ session: Session) {
        store.acknowledge(session)
    }

    func toggleSnooze(_ session: Session) {
        if isSnoozed(session) {
            session.snoozedUntil = nil
        } else {
            session.snoozedUntil = Date().addingTimeInterval(3600)
            notifier.clearDelivered(session)
        }
    }

    func isSnoozed(_ session: Session) -> Bool {
        session.snoozedUntil.map { $0 > Date() } ?? false
    }

    /// NSAlert instead of SwiftUI dialogs: MenuBarExtra window panels don't
    /// reliably present .alert/.confirmationDialog on macOS 14.
    func endSession(_ session: Session) {
        guard let pid = session.pid else { return }
        let alert = NSAlert()
        alert.messageText = "End session in \(session.projectName)?"
        alert.informativeText = "Sends SIGTERM to the claude process (pid \(pid)). "
            + "The session can be reopened later with claude --resume."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)   // .accessory apps must activate for modals
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        kill(pid, SIGTERM)   // SessionEnd hook fires → store transitions naturally
    }

    /// Opens the global config in the configured editor (footer gear).
    func openConfig() {
        let editor = config.effectiveEditor
        Task {
            _ = await Subprocess.run("/usr/bin/open",
                                     ["-a", editor, ArgusConfig.globalPath.path])
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Shared by the row's right-click context menu; the hover strip surfaces
/// the top three directly.
struct RowActionsMenu: View {
    var session: Session
    var actions: RowActions
    var focus: () -> Void

    var body: some View {
        Button("Focus Terminal Tab") { focus() }
        Button("Open in \(actions.config.resolved(for: session.cwd).editor)") {
            actions.openEditor(session)
        }
        Button("Open on GitHub") { actions.openGitHub(session) }
        Button("Open in Linear") { actions.openLinear(session) }
            .disabled(actions.linearURL(session) == nil)
        Divider()
        Button("Copy Session ID") { actions.copySessionId(session) }
        Button("Copy Resume Command") { actions.copyResumeCommand(session) }
        Divider()
        if session.status == .ready {
            Button("Mark Reviewed") { actions.markReviewed(session) }
        }
        Button(actions.isSnoozed(session)
               ? "Unsnooze Notifications" : "Snooze Notifications 1h") {
            actions.toggleSnooze(session)
        }
        if session.pid != nil && session.status != .ended && session.status != .dead {
            Divider()
            Button("End Session…", role: .destructive) { actions.endSession(session) }
        }
    }
}
