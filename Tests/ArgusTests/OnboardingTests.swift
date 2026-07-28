import Foundation
import Testing
@testable import Argus

@Suite struct OnboardingTests {

    @Test func needsOnboardingGate() {
        #expect(OnboardingFlow.needsOnboarding(completedVersion: 0),
                "fresh install (defaults read 0) shows onboarding")
        #expect(!OnboardingFlow.needsOnboarding(completedVersion: OnboardingFlow.currentVersion),
                "completed or skipped current version never re-shows")
        #expect(!OnboardingFlow.needsOnboarding(completedVersion: OnboardingFlow.currentVersion + 1),
                "a downgraded app doesn't re-run onboarding")
    }

    @Test func configFieldsShape() {
        let fields = OnboardingModel.configFields(
            editor: "  Cursor  ", terminal: .ghostty,
            contextAlarm: 120, linearWorkspace: "  ")
        #expect(fields["editor"] as? String == "Cursor", "editor whitespace trimmed")
        #expect(fields["terminal"] as? String == "Ghostty", "terminal stored by raw name")
        #expect(fields["contextAlarm"] as? Int == 95, "alarm clamped to the valid range")
        #expect(fields["linearWorkspace"] == nil, "blank slug omitted, never written empty")

        let blank = OnboardingModel.configFields(
            editor: "", terminal: .iterm, contextAlarm: 65, linearWorkspace: "acme")
        #expect(blank["editor"] as? String == "Zed", "blank editor falls back to the default")
        #expect(blank["linearWorkspace"] as? String == "acme", "slug written when present")
    }
}
