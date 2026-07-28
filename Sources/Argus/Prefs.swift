import Foundation

/// UserDefaults keys shared between views, the notifier, and onboarding.
enum Prefs {
    /// The "Notify on turn end" footer toggle.
    static let notifyOnStop = "notifyOnStop"
    /// Highest onboarding version the user has completed or skipped — the
    /// window shows while it's below OnboardingFlow.currentVersion.
    static let onboardingVersion = "onboardingVersion"
}
