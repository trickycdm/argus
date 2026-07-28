import Foundation
import Testing
@testable import Argus

/// Background-task tracking in the transcript parser: opens come only from
/// structured receipt fields, closes only from task-notification tags on
/// non-assistant lines. The hostile cases mirror real transcript lines where
/// assistant turns quoted receipts and tags verbatim.
@Suite struct TranscriptTaskTests {

    @Test func notificationIdExtraction() {
        let cases: [(line: String, expect: [String], why: String)] = [
            ("<task-notification><task-id>bi0mqm13c</task-id></task-notification>",
             ["bi0mqm13c"], "plain tag extracts the id"),
            ("prefix <task-id>a1</task-id> mid <task-id>b-2_C</task-id> suffix",
             ["a1", "b-2_C"], "multiple tags all extract, in order"),
            ("<task-id></task-id>", [], "empty id is rejected"),
            ("<task-id>has space</task-id>", [], "ids with invalid characters are rejected"),
            ("<task-id>\(String(repeating: "x", count: 65))</task-id>", [],
             "over-long ids are rejected"),
            ("<task-id>unclosed", [], "unterminated tag extracts nothing"),
            ("no tags at all", [], "a line without tags extracts nothing"),
        ]
        for c in cases {
            #expect(TranscriptReader.taskNotificationIds(c.line) == c.expect,
                    Comment(rawValue: c.why))
        }
    }

    @Test func parseTracksBackgroundTaskLifecycle() throws {
        let lines = [
            // Shell launch receipt: opens by structured backgroundTaskId.
            #"{"type":"user","toolUseResult":{"stdout":"","backgroundTaskId":"bg1"}}"#,
            // Agent launch receipt: opens by agentId + async_launched status.
            #"{"type":"user","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"ag1"}}"#,
            // Sidechain receipt: a subagent's own task — must not open.
            #"{"type":"user","isSidechain":true,"toolUseResult":{"backgroundTaskId":"side1"}}"#,
            // Receipt WORDS inside output text: no structured field — must not open.
            #"{"type":"user","toolUseResult":{"stdout":"saw \"backgroundTaskId\" and async_launched in a log"}}"#,
            // toolUseResult that isn't an object: tolerated, never a crash or an open.
            #"{"type":"user","toolUseResult":"backgroundTaskId as plain text"}"#,
            // Assistant line quoting a completion tag verbatim: must not close.
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"<task-notification><task-id>bg1</task-id>"}]}}"#,
            // Real completion (delivery record varies; queue-operation here).
            #"{"type":"queue-operation","operation":"<task-notification> <task-id>ag1</task-id> <status>completed</status>"}"#,
        ]
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-task-test-\(UUID().uuidString).jsonl").path
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try #require(TranscriptReader.parse(path: path, from: 0),
                                  "a transcript with content parses")
        #expect(result.openedTasks == ["bg1", "ag1"],
                "only main-chain structured receipts open tasks")
        #expect(result.closedTasks == ["ag1"],
                "only non-assistant task-notification lines close tasks")
    }
}
