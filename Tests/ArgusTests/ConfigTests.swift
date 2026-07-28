import Foundation
import Testing
@testable import Argus

@Suite struct ConfigTests {

    @Test func repoFileOverridesGlobal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-cfg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{"editor": "RepoEditor", "board": "https://b.example"}"#
            .write(to: dir.appendingPathComponent(".argus.json"), atomically: true, encoding: .utf8)

        let global = ArgusConfig(editor: "GlobalEditor", linearWorkspace: "ws", board: nil, github: nil,
                                 projects: [dir.path: .init(board: "https://global.example", github: nil)])
        let resolved = global.resolved(for: dir.path)
        #expect(resolved.editor == "RepoEditor" && resolved.board == "https://b.example"
                && resolved.linearWorkspace == "ws",
                "repo file overrides global, inherits the rest")
    }

    @Test func terminalFieldDecodes() throws {
        let config = try JSONDecoder().decode(
            ArgusConfig.self, from: Data(#"{"terminal": "Ghostty"}"#.utf8))
        #expect(config.effectiveTerminal == .ghostty, "terminal decodes from JSON")
        let empty = try JSONDecoder().decode(ArgusConfig.self, from: Data("{}".utf8))
        #expect(empty.effectiveTerminal == .iterm, "absent terminal → iTerm2 default")
    }
}
