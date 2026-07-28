import Foundation
import AppKit

/// Focuses the iTerm2 tab/pane hosting a session, using the UUID captured
/// from ITERM_SESSION_ID at hook time. Verified against iTerm's sdef:
/// sessions expose a read-only `id` text property, and `select` makes
/// windows/tabs/sessions visible and selected.
@MainActor
enum ITermFocus {
    enum Result { case focused, notFound, noUUID, error(String) }

    /// "w0t0p0:BBE76183-…" → "BBE76183-…". A bare, colon-less UUID passes
    /// through unchanged — the id property's prefix varies by iTerm version.
    static nonisolated func uuid(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let uuid = text.firstIndex(of: ":").map { String(text[text.index(after: $0)...]) } ?? text
        return uuid.isEmpty ? nil : uuid
    }

    static func focus(_ session: Session, completion: @escaping (Result) -> Void) {
        guard let uuid = session.itermSessionUUID, !uuid.isEmpty else {
            completion(.noUUID)
            return
        }
        // The uuid originates from untrusted hook input and is interpolated
        // into AppleScript source — refuse anything that isn't UUID-shaped.
        guard Escape.isUUIDLike(uuid) else {
            completion(.error("unexpected session id format"))
            return
        }
        // `contains` is deliberate: the id property may or may not carry the
        // w0t0p0: style prefix depending on iTerm version.
        let script = """
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
        run(script) { output, error in
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
        let script = """
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
        run(script) { output, _ in
            guard let output else { return completion([]) }
            completion(Set(output.split(separator: "\n").compactMap { Self.uuid(from: String($0)) }))
        }
    }

    /// Reopens an ended session: new iTerm tab in the session's directory
    /// running `claude --resume <session-id>`.
    static func resume(_ session: Session, completion: @escaping (Result) -> Void) {
        // The session id lands in a shell command line — same untrusted-input
        // rule as focus(): refuse anything that isn't UUID-shaped.
        guard Escape.isUUIDLike(session.id) else {
            completion(.error("unexpected session id format"))
            return
        }
        let command = "cd \(Escape.shellSingleQuoted(session.cwd)) && claude --resume \(session.id)"
        let escaped = Escape.appleScriptString(command)
        let script = """
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
        run(script) { output, error in
            if let error {
                completion(.error(error))
            } else {
                completion(output == "ok" ? .focused : .notFound)
            }
        }
    }

    private static func run(_ script: String,
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
