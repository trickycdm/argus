import Foundation

/// User configuration for row actions. Global file at
/// ~/.config/argus/config.json; a repo can override per-project fields with
/// <cwd>/.argus.json. All fields optional so a partial file only overrides
/// what it names.
struct ArgusConfig: Decodable {
    // All fields default nil so the memberwise init tolerates new fields.
    var editor: String? = nil           // app name for `open -a`
    var terminal: String? = nil         // "iTerm2" | "Ghostty" (global-only)
    var linearWorkspace: String? = nil  // linear.app/<slug>/issue/<ID>
    var contextAlarm: Int? = nil        // alarm threshold in percent (default 65)
    var board: String? = nil            // top-level in repo-local .argus.json
    var github: String? = nil           // top-level in repo-local .argus.json
    var projects: [String: ProjectLinks]? = nil  // global file: keyed by absolute cwd

    struct ProjectLinks: Decodable {
        var board: String?      // Linear fallback when branch has no ticket id
        var github: String?     // overrides the URL derived from git remote
    }

    static let defaultEditor = "Zed"

    /// The editor with the default applied — the one resolution rule for
    /// call sites that don't have a session cwd (e.g. opening the config).
    var effectiveEditor: String { editor ?? Self.defaultEditor }

    /// Only the fallback for sessions whose terminal was never detected
    /// (old logs, unsupported terminals) — live sessions carry their own.
    var effectiveTerminal: TerminalApp {
        terminal.flatMap(TerminalApp.init(configName:)) ?? .iterm
    }

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

/// Writes config fields without disturbing anything else in the file.
/// ArgusConfig stays Decodable-only on purpose: an Encodable round-trip
/// would silently drop keys it doesn't know about — hand-added keys, or
/// fields written by a newer Argus — where the raw-dictionary merge
/// preserves them by construction.
enum ConfigWriter {
    /// One-line docs per key, emitted as an inert "_docs" object in fresh
    /// files — JSON has no comments, and decoders ignore unknown keys.
    static let docs: [String: String] = [
        "editor": "App name for `open -a`, e.g. Zed / Visual Studio Code / Cursor",
        "terminal": "Terminal for sessions Argus can't identify: iTerm2 or Ghostty",
        "linearWorkspace": "Linear workspace slug used for branch-ticket deep links",
        "contextAlarm": "Context-window alarm threshold in percent (10-95)",
        "projects": "Per-repo overrides keyed by absolute path: {board, github}",
    ]

    static let defaults: [String: Any] = [
        "editor": ArgusConfig.defaultEditor,
        "terminal": TerminalApp.iterm.rawValue,
        "contextAlarm": ContextAlarm.defaultPercent,
    ]

    struct MalformedConfig: Error, LocalizedError {
        var errorDescription: String? {
            "existing config isn't a JSON object — fix it by hand first"
        }
    }

    /// Pure merge. nil existing → documented scaffold (docs + defaults) with
    /// `fields` applied over it. Existing content must parse to an object or
    /// this throws — never clobber a file that can't be read back. Only keys
    /// named in `fields` change; everything else survives untouched.
    static func merged(existingJSON: Data?, setting fields: [String: Any]) throws -> Data {
        var dict: [String: Any]
        if let existingJSON {
            guard let parsed = try? JSONSerialization.jsonObject(with: existingJSON),
                  let object = parsed as? [String: Any] else {
                throw MalformedConfig()
            }
            dict = object
        } else {
            dict = defaults
            dict["_docs"] = docs
        }
        for (key, value) in fields { dict[key] = value }
        return try JSONSerialization.data(withJSONObject: dict,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Read-merge-write, creating ~/.config/argus as needed; atomic.
    static func write(fields: [String: Any], to url: URL = ArgusConfig.globalPath) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: url)
        try merged(existingJSON: existing, setting: fields).write(to: url, options: .atomic)
    }

    /// Creates the documented scaffold only when the file is absent —
    /// `open -a` refuses to launch an editor on a missing path.
    static func ensureFileExists(at url: URL = ArgusConfig.globalPath) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try write(fields: [:], to: url)
    }
}
