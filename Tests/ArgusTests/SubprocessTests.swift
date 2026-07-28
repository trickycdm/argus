import Foundation
import Testing
@testable import Argus

@Suite struct EscapeTests {

    @Test func uuidLikeValidation() {
        #expect(Escape.isUUIDLike("BBE76183-8F9C-4F4A-9B0A-0123456789AB"), "real UUID accepted")
        #expect(Escape.isUUIDLike("abc123-def"), "bare hex-and-dash accepted")
        #expect(!Escape.isUUIDLike(""), "empty refused")
        #expect(!Escape.isUUIDLike("abc\" & do shell script \"rm"), "injection refused")
        #expect(!Escape.isUUIDLike("abc def"), "whitespace refused")
    }

    @Test func appleScriptEscaping() {
        #expect(Escape.appleScriptString(#"say "hi" \ done"#) == #"say \"hi\" \\ done"#,
                "quotes and backslashes escaped, backslashes first")
    }

    @Test func shellSingleQuoting() {
        #expect(Escape.shellSingleQuoted("/tmp/plain") == "'/tmp/plain'", "plain path wrapped")
        #expect(Escape.shellSingleQuoted("/tmp/it's here") == #"'/tmp/it'\''s here'"#,
                "embedded quote closed, escaped, reopened")
    }
}

@Suite struct SubprocessTests {

    @Test func largeOutputDoesNotDeadlock() async {
        // 200KB on both streams — far past the ~64KB pipe buffer that
        // deadlocked the old termination-handler-reads-the-pipe design.
        let result = await Subprocess.run(
            "/bin/sh", ["-c", "yes | head -c 200000; yes x | head -c 200000 1>&2"])
        #expect(result.status == 0)
        #expect(result.stdout.count == 200_000, "stdout drained to EOF")
        #expect(result.stderr.count == 200_000, "stderr drained to EOF")
    }

    @Test func missingBinaryReportsError() async {
        let result = await Subprocess.run("/no/such/binary", [])
        #expect(result.status == -1)
        #expect(!result.stderr.isEmpty, "launch failure surfaces in stderr")
    }

    @Test func exitStatusPropagates() async {
        let result = await Subprocess.run("/bin/sh", ["-c", "exit 7"])
        #expect(result.status == 7)
    }
}
