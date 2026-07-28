import Foundation

/// User configuration for row actions. Global file at
/// ~/.config/argus/config.json; a repo can override per-project fields with
/// <cwd>/.argus.json. All fields optional so a partial file only overrides
/// what it names.
struct ArgusConfig: Decodable {
    var editor: String?             // app name for `open -a`
    var linearWorkspace: String?    // linear.app/<slug>/issue/<ID>
    var contextAlarm: Int?          // alarm threshold in percent (default 65)
    var board: String?              // top-level in repo-local .argus.json
    var github: String?             // top-level in repo-local .argus.json
    var projects: [String: ProjectLinks]?   // global file: keyed by absolute cwd

    struct ProjectLinks: Decodable {
        var board: String?      // Linear fallback when branch has no ticket id
        var github: String?     // overrides the URL derived from git remote
    }

    static let defaultEditor = "Zed"

    /// The editor with the default applied — the one resolution rule for
    /// call sites that don't have a session cwd (e.g. opening the config).
    var effectiveEditor: String { editor ?? Self.defaultEditor }

    static var globalPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/argus/config.json")
    }

    static func loadGlobal() -> ArgusConfig {
        load(from: globalPath) ?? ArgusConfig()
    }

    /// Non-nil when the global config file exists but doesn't decode — the
    /// controller surfaces this so a typo isn't just a silent NSLog.
    static func globalLoadError() -> String? {
        guard let data = try? Data(contentsOf: globalPath) else { return nil }
        do {
            _ = try JSONDecoder().decode(ArgusConfig.self, from: data)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func load(from url: URL) -> ArgusConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(ArgusConfig.self, from: data)
        } catch {
            NSLog("Argus: malformed config at \(url.path) — \(error.localizedDescription)")
            return nil
        }
    }

    /// Effective settings for one session's cwd: global config, overridden
    /// field-wise by <cwd>/.argus.json, then by the global projects[cwd]
    /// entry. Read at action time — actions are rare user clicks, so a tiny
    /// synchronous read beats a staleness bug.
    func resolved(for cwd: String) -> Resolved {
        let repo = Self.load(from: URL(fileURLWithPath: cwd).appendingPathComponent(".argus.json"))
        let links = projects?[cwd]
        return Resolved(
            editor: repo?.editor ?? effectiveEditor,
            linearWorkspace: repo?.linearWorkspace ?? linearWorkspace,
            board: repo?.board ?? links?.board,
            github: repo?.github ?? links?.github
        )
    }

    struct Resolved {
        var editor: String
        var linearWorkspace: String?
        var board: String?
        var github: String?
    }
}
