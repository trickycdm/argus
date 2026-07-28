import Foundation
import Darwin

enum Liveness {
    /// Kernel start time (epoch seconds) of a process, or nil if unreadable.
    /// Captured when a session's pid is first seen; a later mismatch means the
    /// pid was reused by an unrelated process.
    static func startTime(_ pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec
    }

    /// Start time of `pid`, but only if the process plausibly existed when
    /// `eventDate`'s event was emitted — a start time after the event means
    /// the pid has since been recycled by an unrelated process (typical when
    /// replaying today's log after the original process died). Small slack
    /// absorbs clock skew between the hook's timestamp and the kernel clock.
    static func validatedStartTime(_ pid: Int32, eventDate: Date) -> UInt64? {
        guard let start = startTime(pid),
              TimeInterval(start) <= eventDate.timeIntervalSince1970 + 5 else { return nil }
        return start
    }

    /// True if the process exists and is still the one we recorded.
    /// Identity is checked by start time, never by name — the Claude CLI sets
    /// its process title to a bare version string ("2.1.220"), so name
    /// matching wrongly declares every live session dead.
    static func isAlive(_ pid: Int32, startedAt: UInt64?) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        let result = kill(pid, 0)
        guard result == 0 || errno == EPERM else { return false }
        guard let startedAt, let current = startTime(pid) else { return true }
        return current == startedAt
    }

    /// Pure: true if an executable path looks like a terminal Claude CLI.
    /// The native installer runs `~/.local/share/claude/versions/<ver>`; a
    /// plain `claude` basename covers Homebrew/manual installs. The Claude
    /// desktop app embeds its own agent binary (basename also `claude`)
    /// inside an .app bundle under `…/Application Support/Claude/claude-code/`
    /// — no terminal CLI lives inside an app bundle, so those are excluded.
    static nonisolated func isClaudeCLI(path: String) -> Bool {
        guard !path.contains(".app/Contents/MacOS/"),
              !path.contains("/Claude/claude-code/") else { return false }
        return path.contains("/share/claude/versions/")
            || (path as NSString).lastPathComponent == "claude"
    }

    /// Pids of running Claude CLI processes, identified by executable path
    /// via `isClaudeCLI`. Blocking — call off the main thread.
    static nonisolated func claudeCLIPids() -> Set<Int32> {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }

        var found: Set<Int32> = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if isClaudeCLI(path: String(cString: buffer)) {
                found.insert(pid)
            }
        }
        return found
    }

    /// Fallback for sessions without a usable pid: consider dead when the
    /// transcript hasn't changed AND no hook event arrived for `window`.
    static func transcriptStale(_ path: String?, lastEventAt: Date,
                                window: TimeInterval = 30 * 60) -> Bool {
        guard Date().timeIntervalSince(lastEventAt) > window else { return false }
        guard let path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(mtime) > window
    }

    /// True if the transcript file changed within `window` — a long-running
    /// tool call fires no hook events, but streamed output still touches the
    /// transcript, so mtime is a second activity signal before declaring a
    /// session stalled.
    static func transcriptActive(_ path: String?, within window: TimeInterval,
                                 now: Date = Date()) -> Bool {
        guard let path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(mtime) < window
    }
}
