import Foundation
import Testing
@testable import Argus

@Suite struct LivenessTests {

    @Test func startTimeIdentity() {
        let me = ProcessInfo.processInfo.processIdentifier
        let start = Liveness.startTime(me)
        #expect(start != nil, "startTime readable for own process")
        #expect(Liveness.isAlive(me, startedAt: start), "alive with matching start time")
        #expect(!Liveness.isAlive(me, startedAt: 12345), "pid-reuse (start mismatch) → dead")
        #expect(!Liveness.isAlive(99999, startedAt: nil), "nonexistent pid → dead")
    }

    @Test func validatedStartTimeRejectsRecycledPids() {
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(Liveness.validatedStartTime(me, eventDate: .now) != nil,
                "own pid existed at a current event")
        #expect(Liveness.validatedStartTime(me, eventDate: Date(timeIntervalSince1970: 0)) == nil,
                "own pid did not exist in 1970 — start time after event = recycled")
    }

    @Test func claudeCLIPathClassification() {
        #expect(Liveness.isClaudeCLI(path: "/Users/me/.local/share/claude/versions/2.1.219"),
                "native installer runs a versioned binary — basename is the version")
        #expect(Liveness.isClaudeCLI(path: "/Users/me/.local/bin/claude"),
                "bare claude basename covers manual installs")
        #expect(Liveness.isClaudeCLI(path: "/opt/homebrew/bin/claude"),
                "Homebrew install is a bare claude basename")
        #expect(!Liveness.isClaudeCLI(
                    path: "/Users/me/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude"),
                "the desktop app's embedded agent is not a terminal session")
        #expect(!Liveness.isClaudeCLI(path: "/usr/local/bin/claudette"),
                "basename must be exactly claude")
        #expect(!Liveness.isClaudeCLI(path: "/Applications/Claude.app/Contents/MacOS/Claude"),
                "the desktop app itself never counts")
    }

    /// The real topology of a daemon-hosted background session, as observed:
    /// bg-spare → bg-pty-host → daemon → the terminal claude that spawned it.
    @Test func owningSessionPidWalksTheDaemonChain() {
        let tree: [Int32: Int32] = [71502: 71496, 71496: 71488, 71488: 13122,
                                    13122: 12415, 12415: 12414]
        let claudePids: Set<Int32> = [71502, 71496, 71488, 13122, 98966]
        func owner(_ pid: Int32) -> Int32? {
            Liveness.owningSessionPid(pid, parent: { tree[$0] },
                                      isClaudeCLI: { claudePids.contains($0) })
        }

        #expect(owner(71502) == 13122,
                "a pool-hosted agent resolves to the terminal that spawned the daemon")
        #expect(owner(13122) == 13122,
                "a terminal session owns itself — its parent is a shell")
        #expect(owner(98966) == 98966, "a terminal with no known parent owns itself")
        #expect(owner(12415) == nil, "a shell is not a claude process at all")
        #expect(owner(0) == nil, "no pid, no owner")
    }

    @Test func owningSessionPidStopsOnAReparentLoop() {
        let claudePids: Set<Int32> = [10, 11]
        let owner = Liveness.owningSessionPid(10, parent: { $0 == 10 ? 11 : 10 },
                                              isClaudeCLI: { claudePids.contains($0) })
        #expect(owner != nil, "the hop cap ends the walk instead of spinning")
    }

    @Test func shellExecutableClassification() {
        for path in ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish"] {
            #expect(Liveness.isShellExecutable(path: path),
                    "\(path) is a shell the Bash tool can run under")
        }
        for path in ["/usr/local/bin/node", "/usr/bin/python3",
                     "/Users/me/.local/bin/claude", "/bin/zshx"] {
            #expect(!Liveness.isShellExecutable(path: path),
                    "\(path) is not a shell — MCP servers and CLIs must not count")
        }
    }
}
