import Foundation

/// Working-tree summary for the row's git chip.
struct GitState: Equatable {
    var dirty: Int
    var ahead: Int?
    var behind: Int?    // nil pair = no upstream / detached head
}

enum GitStatus {
    /// One porcelain-v2 call gets dirty count and ahead/behind together.
    /// GIT_OPTIONAL_LOCKS=0: never take the index lock under a live session.
    static func fetch(cwd: String) async -> GitState? {
        let result = await Subprocess.run(
            "/usr/bin/git",
            ["-C", cwd, "status", "--porcelain=v2", "--branch", "--no-renames"],
            environment: ["GIT_OPTIONAL_LOCKS": "0"])
        guard result.status == 0 else { return nil }   // not a repo, or git failed
        return parse(result.stdout)
    }

    static func parse(_ porcelain: String) -> GitState {
        var state = GitState(dirty: 0, ahead: nil, behind: nil)
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.ab ") {
                // "# branch.ab +2 -1" — absent entirely when no upstream.
                let parts = line.split(separator: " ")
                if parts.count == 4 {
                    state.ahead = Int(parts[2].dropFirst())
                    state.behind = Int(parts[3].dropFirst())
                }
            } else if ["1 ", "2 ", "u ", "? "].contains(where: line.hasPrefix) {
                // Tracked changes (1/2/u) and untracked (?) both count as
                // dirty: "files needing attention".
                state.dirty += 1
            }
        }
        return state
    }

    /// Normalizes a `git remote get-url` result to a browsable https URL.
    /// git@github.com:o/r.git and https://github.com/o/r.git → https://github.com/o/r
    static func webURL(remote: String, branch: String?) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "^(ssh://)?git@", options: .regularExpression) {
            text = "https://" + text[range.upperBound...].replacingOccurrences(of: ":", with: "/")
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        guard text.hasPrefix("https://") || text.hasPrefix("http://") else { return nil }
        if let branch,
           let encoded = branch.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) {
            text += "/tree/\(encoded)"
        }
        return URL(string: text)
    }
}
