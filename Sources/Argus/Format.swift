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

    /// Short display name for a raw model id: "claude-opus-4-6" → "Opus 4.6",
    /// "claude-3-5-haiku-20241022" → "Haiku 3.5". Derived from the id itself
    /// (family word + short numeric tokens), so it needs no model table and
    /// tolerates provider prefixes, date stamps, and suffixes. Unparseable
    /// ids pass through unchanged.
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if let first = parts.first, first.lowercased().hasSuffix("claude") {
            parts.removeFirst()
        }
        guard let family = parts.first(where: {
            $0.rangeOfCharacter(from: .decimalDigits) == nil
        }) else { return id }
        // Short all-digit tokens are version components; long ones are dates.
        let version = parts.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
            .joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
