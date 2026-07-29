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

    /// Executable path of a process, or nil if unreadable.
    static nonisolated func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Parent pid of a process, or nil if unreadable.
    static nonisolated func parentPid(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// True if a process's parent is itself a Claude CLI — which makes it part
    /// of the daemon's own tree (`bg-pty-host`, `bg-spare`) rather than a
    /// top-level session process, so `claudeCLIPids` skips it.
    ///
    /// Says nothing about the session running inside: the daemon's spare-pty
    /// pool hosts human-driven sessions, which is why session classification
    /// goes by SessionStart source instead (`SessionStore.infraSessionStart`).
    static nonisolated func hasClaudeCLIParent(_ pid: Int32) -> Bool {
        guard let ppid = parentPid(pid), ppid > 1,
              let path = executablePath(ppid) else { return false }
        return isClaudeCLI(path: path)
    }

    /// The top-level Claude CLI at the root of `pid`'s claude ancestry — the
    /// terminal process that owns whatever session runs under `pid`.
    ///
    /// A terminal session's own pid has a shell parent, so it resolves to
    /// itself. A session hosted by the daemon's spare-pty pool walks up
    /// `bg-spare → bg-pty-host → daemon → terminal`, which is how a background
    /// agent is attributed to the session that launched it. Returns nil when
    /// `pid` isn't a Claude CLI at all. Blocking — call off the main thread.
    static nonisolated func owningSessionPid(_ pid: Int32) -> Int32? {
        owningSessionPid(pid, parent: parentPid, isClaudeCLI: { child in
            executablePath(child).map(isClaudeCLI(path:)) ?? false
        })
    }

    /// Pure: the ancestry walk behind `owningSessionPid`, with the two process
    /// lookups injected so the real daemon topology can be tested without one.
    static nonisolated func owningSessionPid(_ pid: Int32,
                                             parent: (Int32) -> Int32?,
                                             isClaudeCLI: (Int32) -> Bool) -> Int32? {
        guard pid > 0, isClaudeCLI(pid) else { return nil }
        var current = pid
        // Hop cap: a process tree can't cycle, but a reparent mid-walk could
        // otherwise spin. Real chains are four deep.
        for _ in 0..<8 {
            guard let next = parent(current), next > 1,
                  isClaudeCLI(next) else { return current }
            current = next
        }
        return current
    }

    /// Pids of running top-level Claude CLI processes, identified by executable
    /// path via `isClaudeCLI`, excluding the daemon's own subprocesses (claude
    /// parented by another claude — see `hasClaudeCLIParent`) so a session
    /// hosted by the spare-pty pool is counted once, under the pid its hook
    /// events report. Blocking — call off the main thread.
    static nonisolated func claudeCLIPids() -> Set<Int32> {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }

        var found: Set<Int32> = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let path = executablePath(pid), isClaudeCLI(path: path),
                  !hasClaudeCLIParent(pid) else { continue }
            found.insert(pid)
        }
        return found
    }

    /// Pure: true if an executable path is a login shell — the Bash tool runs
    /// its commands (foreground and background) as a shell child of the
    /// claude process; MCP servers and other children never present as one.
    static nonisolated func isShellExecutable(path: String) -> Bool {
        ["sh", "bash", "zsh", "dash", "fish"]
            .contains((path as NSString).lastPathComponent)
    }

    /// Count of live shell processes directly parented by `pid`. Used to
    /// cross-check open background shell tasks: the shell *is* the task, so
    /// zero shell children while the session isn't working means the tasks
    /// finished even if their completion never reached this session's
    /// transcript (observed: notifications delivered to a fork's transcript
    /// instead). Blocking — call off the main thread.
    static nonisolated func shellChildCount(of pid: Int32) -> Int {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return 0 }

        var shells = 0
        for child in pids.prefix(Int(count)) where child > 0 {
            guard parentPid(child) == pid,
                  let path = executablePath(child), isShellExecutable(path: path)
            else { continue }
            shells += 1
        }
        return shells
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
