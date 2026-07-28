import Foundation

/// Focuses the iTerm2 tab/pane hosting a session, using the UUID captured
/// from ITERM_SESSION_ID at hook time. Verified against iTerm's sdef:
/// sessions expose a read-only `id` text property, and `select` makes
/// windows/tabs/sessions visible and selected.
@MainActor
enum ITermFocus {
    /// "w0t0p0:BBE76183-…" → "BBE76183-…". A bare, colon-less UUID passes
    /// through unchanged — the id property's prefix varies by iTerm version.
    static nonisolated func uuid(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let uuid = text.firstIndex(of: ":").map { String(text[text.index(after: $0)...]) } ?? text
        return uuid.isEmpty ? nil : uuid
    }

    static func focus(_ session: Session,
                      completion: @escaping (TerminalFocus.Result) -> Void) {
        guard let uuid = session.itermSessionUUID, !uuid.isEmpty else {
            completion(.noHandle)
            return
        }
        // The uuid originates from untrusted hook input and is interpolated
        // into AppleScript source — refuse anything that isn't UUID-shaped.
        guard Escape.isUUIDLike(uuid) else {
            completion(.error("unexpected session id format"))
            return
        }
        TerminalFocus.runOsascript(focusScript(uuid: uuid)) { output, error in
            if let error {
                completion(.error(error))
            } else if output == "ok" {
                completion(.focused)
            } else {
                completion(.notFound)
            }
        }
    }

    /// Lists the UUIDs of all sessions currently open in iTerm2. Used to mark
    /// history rows whose terminal tab still exists.
    static func listOpenSessionUUIDs(completion: @escaping (Set<String>) -> Void) {
        TerminalFocus.runOsascript(listScript()) { output, _ in
            guard let output else { return completion([]) }
            completion(Set(output.split(separator: "\n").compactMap { Self.uuid(from: String($0)) }))
        }
    }

    /// Reopens an ended session: new iTerm tab in the session's directory
    /// running `claude --resume <session-id>`.
    static func resume(_ session: Session,
                       completion: @escaping (TerminalFocus.Result) -> Void) {
        // The session id lands in a shell command line — same untrusted-input
        // rule as focus(): refuse anything that isn't UUID-shaped.
        guard Escape.isUUIDLike(session.id) else {
            completion(.error("unexpected session id format"))
            return
        }
        TerminalFocus.runOsascript(resumeScript(cwd: session.cwd, sessionID: session.id)) { output, error in
            if let error {
                completion(.error(error))
            } else {
                completion(output == "ok" ? .focused : .notFound)
            }
        }
    }

    // MARK: - Script builders (pure; callers validate inputs)

    /// `contains` is deliberate: the id property may or may not carry the
    /// w0t0p0: style prefix depending on iTerm version.
    static nonisolated func focusScript(uuid: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if id of s contains "\(uuid)" then
                            select s
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        return "notfound"
        """
    }

    static nonisolated func listScript() -> String {
        """
        tell application "iTerm2"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (id of s) & linefeed
                    end repeat
                end repeat
            end repeat
        end tell
        return out
        """
    }

    /// The command line goes through `write text` into a live shell — the
    /// cwd is shell-quoted first, then the whole command AppleScript-escaped.
    static nonisolated func resumeScript(cwd: String, sessionID: String) -> String {
        let command = "cd \(Escape.shellSingleQuoted(cwd)) && claude --resume \(sessionID)"
        let escaped = Escape.appleScriptString(command)
        return """
        tell application "iTerm2"
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window
                write text "\(escaped)"
            end tell
            activate
        end tell
        return "ok"
        """
    }
}
