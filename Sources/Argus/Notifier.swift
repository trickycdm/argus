import Foundation
import UserNotifications

/// Posts macOS notifications on status transitions. Edge-triggered with a
/// per-session debounce; clears delivered notifications when a session leaves
/// needsYou. UNUserNotificationCenter requires a bundle identifier, so under
/// `swift run` (no bundle) it falls back to NSLog.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter throws unless the process runs from a real
    /// .app bundle — `swift run` and `swift test` both lack one.
    private let hasBundle = Bundle.main.bundleIdentifier != nil
        && Bundle.main.bundlePath.hasSuffix(".app")
    private var lastNotified: [String: Date] = [:]
    private static let debounce: TimeInterval = 60

    /// Called with the session id when the user clicks a notification.
    var onNotificationTap: ((String) -> Void)?

    override init() {
        super.init()
        guard hasBundle else { return }
        // Delegate must be set before launch finishes to receive cold-launch
        // taps — guaranteed because ArgusController is built during App init.
        // Authorization is NOT requested here: onboarding owns that prompt on
        // first run; the controller requests at launch for everyone else.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Idempotent — the system only prompts while status is notDetermined.
    /// The completion fires after the user answers (or immediately when
    /// already determined), on the main actor.
    func requestAuthorization(completion: (@MainActor () -> Void)? = nil) {
        guard hasBundle else {
            completion?()
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                guard let completion else { return }
                Task { @MainActor in completion() }
            }
    }

    /// nil = no bundle (`swift run`/`swift test`), where the notification
    /// center would crash — callers render it as "N/A".
    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard hasBundle else { return nil }
        return await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let id = response.notification.request.content.userInfo["session_id"] as? String {
            onNotificationTap?(id)
        }
    }

    /// Without this, macOS suppresses banners while the app is "active" —
    /// which it is whenever the popover is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    /// ≥65% context alarm, edge-triggered with hysteresis: fires once on
    /// crossing, re-arms only after occupancy falls below 60% (compaction).
    func checkContext(_ session: Session) {
        guard session.status != .ended && session.status != .dead,
              let fraction = session.contextFraction else { return }
        if fraction >= Session.contextAlarmAt {
            guard !session.contextAlerted else { return }
            session.contextAlerted = true
            notify(session, key: "ctx:\(session.id)",
                   body: "Context window at \(Int(fraction * 100))% — compact soon")
        } else if fraction < Session.contextAlarmAt - ContextAlarm.hysteresis {
            session.contextAlerted = false
        }
    }

    func transition(_ session: Session, from old: SessionStatus, to new: SessionStatus) {
        if new == .needsYou && old != .needsYou {
            notify(session, body: session.lastAssistantLine ?? "Claude needs your input")
        }
        if old == .needsYou && new != .needsYou {
            clearDelivered(session)
        }
        if (new == .idle || new == .ready) && old == .working
            && UserDefaults.standard.bool(forKey: Prefs.notifyOnStop) {
            notify(session, body: new == .ready
                   ? "Finished — ready for review"
                   : "Turn finished — waiting for your next prompt")
        }
    }

    /// Wipes delivered notifications for a session — both the transition
    /// notification (keyed by session id) and the context alarm (ctx:<id>).
    /// Used when a session leaves needsYou and when snoozing.
    func clearDelivered(_ session: Session) {
        guard hasBundle else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [session.id, "ctx:\(session.id)"])
    }

    private func notify(_ session: Session, key: String? = nil, body: String) {
        if let until = session.snoozedUntil, Date() < until { return }
        let debounceKey = key ?? session.id
        let now = Date()
        if let last = lastNotified[debounceKey], now.timeIntervalSince(last) < Self.debounce {
            return
        }
        // Expired entries have done their debouncing job — dropping them here
        // keeps the map bounded over a weeks-long run.
        lastNotified = lastNotified.filter { now.timeIntervalSince($0.value) < Self.debounce }
        lastNotified[debounceKey] = now

        guard hasBundle else {
            NSLog("%@", "Argus [\(session.projectName)]: \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = session.projectName
        content.body = body
        content.sound = .default
        content.userInfo = ["session_id": session.id]
        let request = UNNotificationRequest(identifier: debounceKey,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

}
