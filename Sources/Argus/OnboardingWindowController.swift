import AppKit
import SwiftUI
import UserNotifications

/// First-run gate. Bump currentVersion when the setup steps change enough
/// that existing users should see the window once more.
enum OnboardingFlow {
    static let currentVersion = 1

    static func needsOnboarding(completedVersion: Int) -> Bool {
        completedVersion < currentVersion
    }
}

/// State behind the onboarding checklist — a thin shell over tested parts:
/// ConfigWriter persists, HookInstall detects, Notifier prompts. Its only
/// logic of its own is the pure `configFields`.
@MainActor
@Observable
final class OnboardingModel {
    enum Notifications { case checking, unavailable, notDetermined, granted, denied }

    var editor: String
    var terminal: TerminalApp
    var contextAlarm: Int
    var linearWorkspace: String

    private(set) var hookState: HookInstall.State?
    private(set) var installerRunning = false
    private(set) var hookError: String?
    private(set) var notifications: Notifications = .checking
    private(set) var saveError: String?

    let installerPath: String?
    private let notifier: Notifier
    /// Installed by the window controller; argument = completed (vs skipped).
    var finish: ((Bool) -> Void)?

    init(config: ArgusConfig, notifier: Notifier) {
        self.notifier = notifier
        editor = config.effectiveEditor
        terminal = config.effectiveTerminal
        contextAlarm = (config.contextAlarm ?? ContextAlarm.defaultPercent)
            .clamped(to: ContextAlarm.clampPercent)
        linearWorkspace = config.linearWorkspace ?? ""
        installerPath = HookInstall.installerPath()
    }

    func refresh() {
        hookState = HookInstall.detect()
        refreshNotificationStatus()
    }

    func refreshNotificationStatus() {
        Task {
            switch await notifier.authorizationStatus() {
            case nil: notifications = .unavailable
            case .notDetermined?: notifications = .notDetermined
            case .denied?: notifications = .denied
            default: notifications = .granted
            }
        }
    }

    /// Runs scripts/install-hooks.sh (which backs up ~/.claude/settings.json
    /// first) — the one explicit-click path that mutates Claude settings.
    func installHooks() {
        guard let installerPath, !installerRunning else { return }
        installerRunning = true
        hookError = nil
        Task {
            let result = await Subprocess.run("/bin/bash", [installerPath])
            installerRunning = false
            if result.status != 0 {
                let lastLine = result.stderr
                    .split(separator: "\n").last.map(String.init)
                hookError = lastLine ?? "installer exited \(result.status)"
            }
            hookState = HookInstall.detect()
        }
    }

    /// Shown (and copied) when the installer can't be located — Argus is
    /// running from outside its repo checkout.
    var installCommand: String { "cd <your-argus-checkout> && ./scripts/install-hooks.sh" }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    func enableNotifications() {
        notifier.requestAuthorization { [weak self] in
            self?.refreshNotificationStatus()
        }
    }

    func completeSetup() {
        saveError = nil
        do {
            try ConfigWriter.write(fields: Self.configFields(
                editor: editor, terminal: terminal,
                contextAlarm: contextAlarm, linearWorkspace: linearWorkspace))
            finish?(true)
        } catch {
            saveError = "Couldn't save — \(error.localizedDescription)"
        }
    }

    func skip() { finish?(false) }

    /// Pure: the config fields COMPLETE writes. An empty Linear slug is
    /// omitted (never a placeholder value that would be used literally);
    /// a blank editor falls back to the default.
    nonisolated static func configFields(editor: String, terminal: TerminalApp,
                                         contextAlarm: Int,
                                         linearWorkspace: String) -> [String: Any] {
        let name = editor.trimmingCharacters(in: .whitespaces)
        var fields: [String: Any] = [
            "editor": name.isEmpty ? ArgusConfig.defaultEditor : name,
            "terminal": terminal.rawValue,
            "contextAlarm": contextAlarm.clamped(to: ContextAlarm.clampPercent),
        ]
        let slug = linearWorkspace.trimmingCharacters(in: .whitespaces)
        if !slug.isEmpty { fields["linearWorkspace"] = slug }
        return fields
    }
}

/// Distinct NSWindow subclass so SessionListView.dismissPopover can tell the
/// onboarding window apart from the MenuBarExtra panel it wants to close.
final class OnboardingWindow: NSWindow {}

/// Presents the first-run checklist as an AppKit window. Deliberately not a
/// SwiftUI Window scene: on macOS 14 (our floor) scenes are restored/shown
/// at launch — `.defaultLaunchBehavior(.suppressed)` is macOS 15+. The app
/// stays a `.accessory` MenuBarExtra throughout; activation is required for
/// the window to come forward (same rule as RowActions.endSession).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let notifier: Notifier
    private var window: OnboardingWindow?
    /// Fires on any close (completed or skipped) so config gets re-applied.
    var onFinished: (() -> Void)?

    init(notifier: Notifier) {
        self.notifier = notifier
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = OnboardingModel(config: ArgusConfig.loadGlobal(), notifier: notifier)
        model.finish = { [weak self] _ in self?.window?.close() }
        let hosting = NSHostingView(rootView: OnboardingView(model: model))
        let window = OnboardingWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false   // the controller owns the lifetime
        window.backgroundColor = NSColor(Deck.bg)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Any close — COMPLETE, SKIP, or the traffic light — records the
    /// version, so onboarding shows once and never nags. Re-entry lives in
    /// the popover footer's SETUP button.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(OnboardingFlow.currentVersion,
                                      forKey: Prefs.onboardingVersion)
            window = nil
            onFinished?()
        }
    }
}
