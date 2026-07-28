import Foundation
import Testing
@testable import Argus

@Suite struct ConfigWriterTests {

    @Test func freshScaffoldHasDocsAndDefaults() throws {
        let data = try ConfigWriter.merged(existingJSON: nil, setting: ["editor": "Cursor"])
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["_docs"] is [String: Any], "fresh file carries the inline docs")
        #expect(dict["editor"] as? String == "Cursor", "chosen field applied over defaults")
        #expect(dict["terminal"] as? String == "iTerm2", "defaults present")
        #expect(dict["contextAlarm"] as? Int == 65, "defaults present")
        let config = try JSONDecoder().decode(ArgusConfig.self, from: data)
        #expect(config.editor == "Cursor", "scaffold round-trips through the real decoder")
    }

    @Test func mergePreservesUnknownKeys() throws {
        let existing = Data(#"{"editor": "Zed", "myCustomKey": [1, 2], "contextAlarm": 80}"#.utf8)
        let data = try ConfigWriter.merged(existingJSON: existing, setting: ["editor": "Cursor"])
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["myCustomKey"] is [Any], "hand-added key survives the merge")
        #expect(dict["editor"] as? String == "Cursor", "named field changes")
        #expect(dict["contextAlarm"] as? Int == 80, "unnamed field untouched")
        #expect(dict["_docs"] == nil, "docs are not injected into existing files")
    }

    @Test func malformedExistingThrows() {
        #expect(throws: (any Error).self, "unparseable file must not be clobbered") {
            _ = try ConfigWriter.merged(existingJSON: Data("not json".utf8), setting: [:])
        }
        #expect(throws: (any Error).self, "non-object JSON must not be clobbered") {
            _ = try ConfigWriter.merged(existingJSON: Data("[1, 2]".utf8), setting: [:])
        }
    }

    @Test func writeCreatesDirectoriesAndEnsureNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-writer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/config.json")

        try ConfigWriter.ensureFileExists(at: url)
        let scaffold = try JSONDecoder().decode(ArgusConfig.self, from: Data(contentsOf: url))
        #expect(scaffold.effectiveEditor == "Zed", "scaffold created with defaults")

        try ConfigWriter.write(fields: ["editor": "Cursor"], to: url)
        try ConfigWriter.ensureFileExists(at: url)
        let config = try JSONDecoder().decode(ArgusConfig.self, from: Data(contentsOf: url))
        #expect(config.editor == "Cursor", "ensureFileExists never resets an existing file")
    }
}
