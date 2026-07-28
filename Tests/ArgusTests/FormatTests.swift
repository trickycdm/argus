import Foundation
import Testing
@testable import Argus

@Suite struct FormatTests {

    @Test func elapsedInstrumentStyle() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(Format.elapsed(since: start, now: start.addingTimeInterval(42)) == "00:42")
        #expect(Format.elapsed(since: start, now: start.addingTimeInterval(252)) == "04:12")
        #expect(Format.elapsed(since: start, now: start.addingTimeInterval(3852)) == "1:04:12")
        #expect(Format.elapsed(since: start.addingTimeInterval(10), now: start) == "00:00",
                "future statusSince clamps to zero")
    }

    @Test func tokenFormatting() {
        #expect(Format.tokens(999) == "999 tok")
        #expect(Format.tokens(1500) == "1.5k tok")
        #expect(Format.tokens(2_300_000) == "2.3M tok")
    }

    @Test func modelDisplayNames() {
        #expect(Format.modelName("claude-fable-5") == "Fable 5")
        #expect(Format.modelName("claude-opus-4-6") == "Opus 4.6")
        #expect(Format.modelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5",
                "date stamp is not a version component")
        #expect(Format.modelName("claude-3-5-haiku-20241022") == "Haiku 3.5",
                "old version-before-family ids still resolve")
        #expect(Format.modelName("us.anthropic.claude-sonnet-4-5-20250929-v1:0") == "Sonnet 4.5",
                "Bedrock-style prefix and suffix are ignored")
        #expect(Format.modelName("claude-3-5-sonnet-latest") == "Sonnet 3.5",
                "family is the first digit-free token")
        #expect(Format.modelName("claude-42") == "claude-42",
                "no family word → raw id passes through")
    }

    @Test func oneLineTruncation() {
        #expect(TranscriptReader.oneLine("  first line  \nsecond") == "first line")
        let long = String(repeating: "a", count: 150)
        let out = TranscriptReader.oneLine(long)
        #expect(out.count == 121 && out.hasSuffix("…"), "long lines cut at 120 + ellipsis")
    }

    @Test func itermUUIDStripping() {
        #expect(ITermFocus.uuid(from: "w0t0p0:BBE76183-8F9C") == "BBE76183-8F9C",
                "prefixed id keeps the UUID part")
        #expect(ITermFocus.uuid(from: "BBE76183-8F9C") == "BBE76183-8F9C",
                "bare UUID passes through")
        #expect(ITermFocus.uuid(from: "  ") == nil, "blank → nil")
        #expect(ITermFocus.uuid(from: "w0t0p0:") == nil, "prefix with empty UUID → nil")
    }
}
