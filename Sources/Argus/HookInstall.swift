import Foundation

/// Detects whether the Argus capture hook is wired into Claude Code's
/// settings, and locates the repo's installer script so onboarding can run
/// it. Detection is read-only; only an explicit user click mutates
/// ~/.claude/settings.json — via scripts/install-hooks.sh, which backs the
/// file up first.
enum HookInstall {
    enum State { case installed, missing }

    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func detect() -> State {
        guard let data = try? Data(contentsOf: settingsPath) else { return .missing }
        return isInstalled(settingsJSON: data) ? .installed : .missing
    }

    /// Pure: does any hook command reference argus-hook.sh? Walks the shape
    /// install-hooks.sh writes — hooks.<Event>[n].hooks[m].command — and
    /// reads malformed or unexpected JSON as not installed.
    static func isInstalled(settingsJSON: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: settingsJSON)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for matchers in hooks.values {
            guard let matchers = matchers as? [[String: Any]] else { continue }
            for matcher in matchers {
                guard let entries = matcher["hooks"] as? [[String: Any]] else { continue }
                for entry in entries
                where (entry["command"] as? String)?.contains("argus-hook.sh") == true {
                    return true
                }
            }
        }
        return false
    }

    /// Pure path math: where install-hooks.sh lives relative to how Argus
    /// runs — dist/Argus.app inside the repo checkout, or `swift run` from
    /// the repo root.
    static func installerCandidates(bundlePath: String, cwd: String) -> [String] {
        [
            (bundlePath as NSString).deletingLastPathComponent + "/../scripts/install-hooks.sh",
            cwd + "/scripts/install-hooks.sh",
        ].map { ($0 as NSString).standardizingPath }
    }

    /// First locatable installer; nil → onboarding shows the command to run
    /// by hand instead of a button.
    static func installerPath() -> String? {
        installerCandidates(bundlePath: Bundle.main.bundlePath,
                            cwd: FileManager.default.currentDirectoryPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
