import Foundation
import Testing
@testable import Argus

@MainActor
@Suite struct TerminalTests {

    @Test func detectClassifiesHostTerminal() {
        #expect(TerminalApp.detect(itermID: "w0t0p0:AAA", termProgram: nil) == .iterm,
                "iTerm id alone → iterm")
        #expect(TerminalApp.detect(itermID: "w0t0p0:AAA", termProgram: "tmux") == .iterm,
                "iTerm id wins — tmux overwrites TERM_PROGRAM")
        #expect(TerminalApp.detect(itermID: "", termProgram: "ghostty") == .ghostty,
                "TERM_PROGRAM=ghostty → ghostty")
        #expect(TerminalApp.detect(itermID: "", termProgram: "Ghostty") == .ghostty,
                "TERM_PROGRAM match is case-insensitive")
        #expect(TerminalApp.detect(itermID: "", termProgram: "Apple_Terminal") == nil,
                "unsupported terminal → unknown")
        #expect(TerminalApp.detect(itermID: "", termProgram: nil) == nil,
                "v1 log line (no term field) → unknown")
        #expect(TerminalApp.detect(itermID: "w0t0p0:", termProgram: nil) == nil,
                "empty uuid after prefix is not an iTerm id")
    }

    @Test func configNameParsing() {
        #expect(TerminalApp(configName: "iterm") == .iterm, "short name accepted")
        #expect(TerminalApp(configName: "iTerm2") == .iterm, "canonical name accepted")
        #expect(TerminalApp(configName: "GHOSTTY") == .ghostty, "case-insensitive")
        #expect(TerminalApp(configName: "kitty") == nil, "unknown terminal rejected")
        #expect(ArgusConfig().effectiveTerminal == .iterm, "default fallback is iTerm2")
        #expect(ArgusConfig(terminal: "ghostty").effectiveTerminal == .ghostty,
                "config value parsed")
        #expect(ArgusConfig(terminal: "kitty").effectiveTerminal == .iterm,
                "unknown config value degrades to the default")
    }

    @Test func backendSelection() {
        let session = Session(id: "s1", cwd: "/tmp", status: .idle, at: Date())
        #expect(TerminalFocus.backend(for: session, fallback: .ghostty) == .ghostty,
                "unknown terminal uses the fallback")
        session.terminal = .iterm
        #expect(TerminalFocus.backend(for: session, fallback: .ghostty) == .iterm,
                "detected terminal beats the fallback")
    }

    @Test func ghosttyScripts() {
        let focus = GhosttyFocus.focusScript(pid: 4242)
        #expect(focus.contains("terminals whose pid is 4242"),
                "focus matches on the claude pid")
        #expect(focus.contains(#"tell application "Ghostty""#), "targets Ghostty")

        let resume = GhosttyFocus.resumeScript(cwd: #"/tmp/has " quote\"#, sessionID: "ABC-123")
        #expect(resume.contains(#"initial working directory: "/tmp/has \" quote\\""#),
                "cwd is AppleScript-escaped (record field, no shell quoting)")
        #expect(resume.contains("claude --resume ABC-123"), "resume command included")
        #expect(resume.contains("wait after command: true"),
                "window survives the command exiting")
    }

    @Test func itermScripts() {
        #expect(ITermFocus.focusScript(uuid: "ABC-123")
            .contains(#"if id of s contains "ABC-123""#),
                "focus matches the session uuid with contains")
        let resume = ITermFocus.resumeScript(cwd: "/tmp/it's", sessionID: "ABC-123")
        #expect(resume.contains(#"cd '/tmp/it'\\''s' && claude --resume ABC-123"#),
                "cwd shell-quoted then AppleScript-escaped")
    }

    @Test func ghosttyFriendlyErrors() {
        #expect(GhosttyFocus.friendlyError(
            "execution error: Not authorized to send Apple events to Ghostty. (-1743)")
            .contains("Automation"), "TCC denial points at System Settings")
        #expect(GhosttyFocus.friendlyError(
            "Ghostty got an error: terminals doesn't understand the message. (-1708)")
            .contains("1.3"), "missing dictionary points at the version requirement")
        #expect(GhosttyFocus.friendlyError("mystery failure") == "mystery failure",
                "unknown errors pass through")
    }
}
