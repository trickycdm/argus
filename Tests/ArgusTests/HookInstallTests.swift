import Foundation
import Testing
@testable import Argus

@Suite struct HookInstallTests {

    @Test func recognizesInstallerOutputShape() {
        let json = #"""
        {"model": "opus", "hooks": {
            "SessionStart": [{"hooks": [{"type": "command",
                "command": "/Users/x/repos/argus/hooks/argus-hook.sh SessionStart"}]}],
            "Stop": [{"matcher": "", "hooks": [{"type": "command",
                "command": "/Users/x/repos/argus/hooks/argus-hook.sh Stop"}]}]
        }}
        """#
        #expect(HookInstall.isInstalled(settingsJSON: Data(json.utf8)),
                "installer-written shape detected")
    }

    @Test func ignoresForeignHooks() {
        let json = #"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay /tmp/done.mp3"}]}]}}
        """#
        #expect(!HookInstall.isInstalled(settingsJSON: Data(json.utf8)),
                "other hooks don't count as installed")
    }

    @Test func toleratesMissingAndMalformedSettings() {
        #expect(!HookInstall.isInstalled(settingsJSON: Data("{}".utf8)), "no hooks key")
        #expect(!HookInstall.isInstalled(settingsJSON: Data("not json".utf8)), "malformed")
        #expect(!HookInstall.isInstalled(settingsJSON: Data(#"{"hooks": "nope"}"#.utf8)),
                "unexpected hooks type")
    }

    @Test func installerCandidatePathMath() {
        let candidates = HookInstall.installerCandidates(
            bundlePath: "/Users/me/repos/argus/dist/Argus.app",
            cwd: "/Users/me/elsewhere")
        #expect(candidates.first == "/Users/me/repos/argus/scripts/install-hooks.sh",
                "dist bundle resolves to the repo's installer")
        #expect(candidates.last == "/Users/me/elsewhere/scripts/install-hooks.sh",
                "cwd covers swift run from a checkout")
    }
}
