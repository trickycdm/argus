import Foundation

/// Pure display formatting — no UI types, fully unit-testable.
enum Format {
    /// Instrument-style elapsed time: 00:42 · 04:12 · 1:04:12.
    static func elapsed(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count) tok"
        case ..<1_000_000: return String(format: "%.1fk tok", Double(count) / 1000)
        default: return String(format: "%.1fM tok", Double(count) / 1_000_000)
        }
    }
}
