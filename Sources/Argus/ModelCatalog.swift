import Foundation

/// Single source of truth for per-model context windows and pricing.
/// Matching is true longest-prefix, so row order can never regress it.
/// Rates are $ per million tokens; cache read ≈ 0.1× base input, cache
/// write ≈ 1.25× (5-minute TTL). Hardcoded and therefore prone to going
/// stale — costs are estimates, `/cost` in the CLI is authoritative.
enum ModelCatalog {
    struct Entry {
        let prefix: String
        let contextWindow: Int
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static let entries: [Entry] = [
        Entry(prefix: "claude-fable", contextWindow: 1_000_000,
              input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        Entry(prefix: "claude-mythos", contextWindow: 1_000_000,
              input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        Entry(prefix: "claude-opus-5", contextWindow: 1_000_000,
              input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        Entry(prefix: "claude-opus", contextWindow: 200_000,
              input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        Entry(prefix: "claude-sonnet-5", contextWindow: 1_000_000,
              input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        Entry(prefix: "claude-sonnet", contextWindow: 200_000,
              input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        Entry(prefix: "claude-haiku", contextWindow: 200_000,
              input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
    ]

    static func entry(for model: String?) -> Entry? {
        guard let model else { return nil }
        return entries.filter { model.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
    }

    /// Fallback window for unknown models, until the transcript exposes the
    /// window directly.
    static let defaultContextWindow = 200_000
}

/// The context alarm's tunables, gathered in one place: default threshold,
/// the clamp applied to the user's configured percent, and the hysteresis
/// band below the threshold where the latch holds before re-arming.
enum ContextAlarm {
    static let defaultPercent = 65
    static let clampPercent = 10...95
    static let hysteresis = 0.05
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
