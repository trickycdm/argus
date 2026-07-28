import Foundation
import AppKit

/// The terminal applications Argus can drive. Which app hosts a session is
/// detected per session from hook-captured environment values; the config
/// `terminal` value only fills in for sessions that predate detection.
enum TerminalApp: String {
    case iterm = "iTerm2"
    case ghostty = "Ghostty"

    var bundleID: String {
        switch self {
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    /// Classifies a session's host terminal. ITERM_SESSION_ID wins over
    /// TERM_PROGRAM: it survives tmux (which overwrites TERM_PROGRAM) and is
    /// the handle iTerm focus actually needs. nil = unknown terminal (old
    /// logs, Terminal.app, …) — callers fall back to the config default.
    static func detect(itermID: String, termProgram: String?) -> TerminalApp? {
        if ITermFocus.uuid(from: itermID) != nil { return .iterm }
        if termProgram?.lowercased() == "ghostty" { return .ghostty }
        return nil
    }

    /// Parses the config `terminal` value, tolerantly: "iterm", "iTerm2",
    /// "ghostty" in any case.
    init?(configName: String) {
        switch configName.lowercased() {
        case "iterm", "iterm2": self = .iterm
        case "ghostty": self = .ghostty
        default: return nil
        }
    }
}

/// Routes focus/resume to the backend for a session's terminal. `fallback`
/// (the config `terminal`, default iTerm2) covers sessions whose terminal
/// was never detected.
@MainActor
enum TerminalFocus {
    /// Shared result vocabulary: `noHandle` = no way to locate the tab (no
    /// iTerm UUID / no Ghostty pid) — callers fall through to resume.
    enum Result { case focused, notFound, noHandle, error(String) }

    static nonisolated func backend(for session: Session,
                                    fallback: TerminalApp) -> TerminalApp {
        session.terminal ?? fallback
    }

    static func focus(_ session: Session, fallback: TerminalApp,
                      completion: @escaping (Result) -> Void) {
        let app = backend(for: session, fallback: fallback)
        // Focus can't succeed when the terminal isn't running, and merely
        // asking via `tell application` would launch it — short-circuit.
        // Resume (the .notFound path) launches the terminal deliberately.
        guard isRunning(app) else {
            completion(.notFound)
            return
        }
        switch app {
        case .iterm: ITermFocus.focus(session, completion: completion)
        case .ghostty: GhosttyFocus.focus(session, completion: completion)
        }
    }

    static func resume(_ session: Session, fallback: TerminalApp,
                       completion: @escaping (Result) -> Void) {
        switch backend(for: session, fallback: fallback) {
        case .iterm: ITermFocus.resume(session, completion: completion)
        case .ghostty: GhosttyFocus.resume(session, completion: completion)
        }
    }

    static func isRunning(_ app: TerminalApp) -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == app.bundleID }
    }

    /// The one osascript entry point shared by every backend — still the
    /// single Subprocess.run path for AppleScript.
    static func runOsascript(_ script: String,
                             completion: @escaping @MainActor (String?, String?) -> Void) {
        Task {
            let result = await Subprocess.run("/usr/bin/osascript", ["-e", script])
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status != 0 {
                completion(nil, err.isEmpty ? "osascript exit \(result.status)" : err)
            } else {
                completion(out, nil)
            }
        }
    }
}
