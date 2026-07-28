import Foundation
import Testing
@testable import Argus

/// Serialized: these tests mutate the process-wide alarm threshold
/// (`Session.contextAlarmAt`) and must not interleave.
@MainActor
@Suite(.serialized) struct ContextTests {

    @Test func contextWindowTable() {
        #expect(Session.contextWindow(for: "claude-opus-5") == 1_000_000, "opus-5 window is 1M")
        #expect(Session.contextWindow(for: "claude-fable-5") == 1_000_000, "fable window is 1M")
        #expect(Session.contextWindow(for: "claude-sonnet-5") == 1_000_000, "sonnet-5 window is 1M")
        #expect(Session.contextWindow(for: "claude-sonnet-4-6") == 200_000, "sonnet-4.6 window is 200k")
        #expect(Session.contextWindow(for: "some-model") == 200_000, "unknown model defaults to 200k")
        #expect(Session.contextWindow(for: nil) == 200_000, "nil model defaults to 200k")
    }

    @Test func modelCatalogLongestPrefixWins() {
        // "claude-opus-5-20260115" matches both "claude-opus" and
        // "claude-opus-5" — the longer, more specific row must win.
        let opus5 = ModelCatalog.entry(for: "claude-opus-5-20260115")
        #expect(opus5?.prefix == "claude-opus-5" && opus5?.contextWindow == 1_000_000)
        let legacyOpus = ModelCatalog.entry(for: "claude-opus-4-6")
        #expect(legacyOpus?.prefix == "claude-opus" && legacyOpus?.contextWindow == 200_000)
        #expect(ModelCatalog.entry(for: "gpt-x") == nil, "unknown family → nil")
        #expect(ModelCatalog.entry(for: nil) == nil, "nil model → nil")
    }

    @Test func pricingEstimate() {
        var tokens = TokenTotals()
        tokens.input = 1_000_000
        tokens.output = 1_000_000
        #expect(Pricing.estimate(model: "claude-opus-5", tokens: tokens) == 30,
                "opus-5: $5 in + $25 out per MTok — not the fable tier")
        #expect(Pricing.estimate(model: "claude-fable-5", tokens: tokens) == 60,
                "fable: $10 in + $50 out per MTok")
        #expect(Pricing.estimate(model: "unknown", tokens: tokens) == nil, "unknown model → nil")
    }

    @Test func contextFraction() {
        let session = Session(id: "c1", cwd: "/tmp/proj", status: .idle, at: .now)
        session.model = "claude-sonnet-4-6"
        session.contextTokens = 130_000
        #expect(session.contextFraction == 0.65, "130k/200k → 65%")
    }

    @Test func alarmLatchAndHysteresis() {
        Session.contextAlarmAt = 0.65
        defer { Session.contextAlarmAt = 0.65 }
        let session = Session(id: "c2", cwd: "/tmp/proj", status: .idle, at: .now)
        session.model = "claude-sonnet-4-6"
        session.contextTokens = 130_000
        let notifier = Notifier()

        notifier.checkContext(session)
        #expect(session.contextAlerted, "alarm latches at 65%")
        session.contextTokens = 140_000
        notifier.checkContext(session)
        #expect(session.contextAlerted, "no re-fire while latched")
        session.contextTokens = 122_000   // 61% — inside hysteresis band
        notifier.checkContext(session)
        #expect(session.contextAlerted, "stays latched in 60–65% band")
        session.contextTokens = 110_000   // 55% — compacted
        notifier.checkContext(session)
        #expect(!session.contextAlerted, "re-arms below 60%")
    }

    @Test func configurableThreshold() {
        Session.contextAlarmAt = 0.50
        defer { Session.contextAlarmAt = 0.65 }
        let session = Session(id: "c3", cwd: "/tmp/proj", status: .idle, at: .now)
        session.model = "claude-sonnet-4-6"
        session.contextTokens = 100_000   // 50% of 200k
        session.contextAlerted = false
        Notifier().checkContext(session)
        #expect(session.contextAlerted, "alarm respects configured 50% threshold")
    }
}
