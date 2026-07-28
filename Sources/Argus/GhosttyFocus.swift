import Foundation

/// Drives Ghostty via its AppleScript dictionary (1.3+, a preview feature
/// that users can disable with `macos-applescript = false`). Ghostty exposes
/// no per-session env var, so live sessions are located by the claude CLI's
/// pid — `pid of terminal` is the surface's foreground process. Once claude
/// exits that handle is gone, so ended Ghostty sessions can't be located and
/// always resume into a fresh window.
@MainActor
enum GhosttyFocus {
    static func focus(_ session: Session,
                      completion: @escaping (TerminalFocus.Result) -> Void) {
        guard let pid = session.pid else {
            completion(.noHandle)
            return
        }
        TerminalFocus.runOsascript(focusScript(pid: pid)) { output, error in
            if let error {
                completion(.error(friendlyError(error)))
            } else if output == "ok" {
                completion(.focused)
            } else {
                completion(.notFound)
            }
        }
    }

    /// Opens a new Ghostty window in the session's directory running
    /// `claude --resume`. AppleScript is the only correct macOS path — the
    /// ghostty CLI's +new-window is GTK-only and `open -na` spawns a second
    /// app instance.
    static func resume(_ session: Session,
                       completion: @escaping (TerminalFocus.Result) -> Void) {
        // The session id lands in the configuration's command string — same
        // untrusted-input rule as the iTerm backend.
        guard Escape.isUUIDLike(session.id) else {
            completion(.error("unexpected session id format"))
            return
        }
        TerminalFocus.runOsascript(resumeScript(cwd: session.cwd, sessionID: session.id)) { output, error in
            if let error {
                completion(.error(friendlyError(error)))
            } else {
                completion(output == "ok" ? .focused : .notFound)
            }
        }
    }

    // MARK: - Script builders (pure; callers validate inputs)

    /// `pid` is interpolated as a number — injection-safe by type.
    static nonisolated func focusScript(pid: Int32) -> String {
        """
        tell application "Ghostty"
            set matches to terminals whose pid is \(pid)
            if (count of matches) > 0 then
                focus item 1 of matches
                activate
                return "ok"
            end if
            activate
        end tell
        return "notfound"
        """
    }

    /// The cwd and command are record fields of `new window with
    /// configuration`, not a shell command line — AppleScript string escaping
    /// only, unlike ITermFocus.resumeScript which must also shell-quote.
    static nonisolated func resumeScript(cwd: String, sessionID: String) -> String {
        """
        tell application "Ghostty"
            new window with configuration {initial working directory: "\(Escape.appleScriptString(cwd))", command: "claude --resume \(sessionID)", wait after command: true}
            activate
        end tell
        return "ok"
        """
    }

    /// The dictionary being a preview feature makes "Ghostty doesn't speak
    /// AppleScript" a normal condition, not a bug — translate the raw
    /// osascript error into what the user can do about it.
    static nonisolated func friendlyError(_ raw: String) -> String {
        if raw.contains("-1743") || raw.localizedCaseInsensitiveContains("not authorized") {
            return "Ghostty automation not allowed — enable Argus in System Settings"
                + " → Privacy & Security → Automation"
        }
        // -1708 = event not handled; -2740/-2741 = script didn't compile —
        // all three are what an absent scripting dictionary looks like.
        if raw.contains("-1708") || raw.contains("-2740") || raw.contains("-2741")
            || raw.localizedCaseInsensitiveContains("doesn't understand") {
            return "Ghostty scripting unavailable — requires Ghostty 1.3+"
                + " with macos-applescript enabled"
        }
        return raw
    }
}
