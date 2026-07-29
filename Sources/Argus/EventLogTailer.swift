import Foundation

/// Tails the daily Argus event log. Replays yesterday's and today's files on
/// start (so app state is fully rebuilt from the log), then delivers new
/// events as the hooks append them. DispatchSource does the low-latency work;
/// a 2s timer covers file creation, midnight rollover, and
/// coalesced-notification gaps.
@MainActor
final class EventLogTailer {
    static nonisolated let defaultLogDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Argus")

    var onReplay: (([HookEvent]) -> Void)?
    var onEvent: ((HookEvent) -> Void)?

    private let logDir: URL
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var currentDay = ""
    private let decoder = JSONDecoder()

    init(logDir: URL = EventLogTailer.defaultLogDir) {
        self.logDir = logDir
    }

    func start() {
        pruneOldLogs()
        currentDay = Self.dayString(Date())
        // Sessions routinely outlive midnight, and one parked at an idle
        // prompt emits nothing to re-announce itself — replaying today's file
        // alone leaves every overnight session invisible with no way back
        // except restarting it. Yesterday's events go first so the whole
        // replay stays in order; the store's liveness pass retires whatever
        // didn't survive the night.
        var replayed = readArchived(day: Self.dayString(Self.dayBefore(Date())))
        let opened = openCurrentFile()
        if opened { replayed += drainEvents() }
        onReplay?(replayed)
        if opened { attachSource() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detachFile()
    }

    deinit {
        timer?.invalidate()
    }

    private var currentPath: URL {
        logDir.appendingPathComponent("events-\(currentDay).jsonl")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Calendar-aware so a DST boundary can't land back on the same day.
    static func dayBefore(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: date)
            ?? date.addingTimeInterval(-24 * 3600)
    }

    /// Reads a completed day's log in full, then leaves it closed — only
    /// today's file is tailed. Malformed lines are counted, not logged one by
    /// one: an archive replay would turn a corrupt file into a log flood.
    private func readArchived(day: String) -> [HookEvent] {
        let url = logDir.appendingPathComponent("events-\(day).jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        var events: [HookEvent] = []
        var skipped = 0
        for line in data.split(separator: UInt8(ascii: "\n"),
                               omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(HookEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            NSLog("Argus: skipped \(skipped) malformed line(s) in events-\(day).jsonl")
        }
        return events
    }

    private func openCurrentFile() -> Bool {
        guard let h = try? FileHandle(forReadingFrom: currentPath) else { return false }
        handle = h
        offset = 0
        partial.removeAll()
        return true
    }

    private func attachSource() {
        guard let handle else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend, .write],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            for event in self.drainEvents() { self.onEvent?(event) }
        }
        src.activate()
        source = src
    }

    private func detachFile() {
        if let source {
            // cancel() is asynchronous and the source may still reference
            // the descriptor — close it only once cancellation completes.
            let handle = handle
            source.setCancelHandler { try? handle?.close() }
            source.cancel()
        } else {
            try? handle?.close()
        }
        source = nil
        handle = nil
        offset = 0
        partial.removeAll()
    }

    private func poll() {
        let today = Self.dayString(Date())
        if today != currentDay {
            // Midnight rollover: finish the old file, switch to the new one.
            for event in drainEvents() { onEvent?(event) }
            detachFile()
            currentDay = today
            pruneOldLogs()   // the app may run for weeks without a restart
        }
        if handle == nil {
            guard openCurrentFile() else { return }
            attachSource()
        }
        // Fallback for coalesced/missed DispatchSource notifications.
        for event in drainEvents() { onEvent?(event) }
    }

    /// Reads all complete lines appended since the last drain.
    private func drainEvents() -> [HookEvent] {
        guard let handle else { return [] }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Append-only file shrank — recreated externally; start over.
            offset = 0
            partial.removeAll()
        }
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)

        partial.append(data)
        var events: [HookEvent] = []
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial = Data(partial[partial.index(after: newline)...])
            guard !line.isEmpty else { continue }
            if let event = try? decoder.decode(HookEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                NSLog("Argus: skipping malformed event line")
            }
        }
        return events
    }

    private func pruneOldLogs() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("events-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
