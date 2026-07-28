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
