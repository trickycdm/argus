# Concurrency

> _Cross-cutting standard — applies to every module. Argus builds in Swift 5 language mode (`.swiftLanguageMode(.v5)` in `Package.swift`), so the compiler does **not** enforce strict concurrency — these rules are what keeps the app race-free until a future migration turns the checker on._

The app's concurrency model is deliberately simple: **everything stateful is on the main actor; everything slow happens off it and reports back.**

## The rules

- **Stateful controllers are `@MainActor` (`SessionStore`, `EventLogTailer`, `TranscriptReader`, `Notifier`, `RowActions`, `ITermFocus`).** State the isolation on the type, not per-member. Mark non-observed stored properties `@ObservationIgnored` so bookkeeping doesn't trigger view renders — `SessionStore.now` is the exemplar: the 1s maintenance clock is deliberately not observable, and rows drive elapsed labels from `TimelineView` instead.

- **All subprocess work goes through `Subprocess.run` — never hand-roll `Process` + `Pipe`.** The helper installs its termination handler before `run()` and drains both pipes concurrently to EOF on GCD threads. The bug it prevents is real: reading a pipe inside `terminationHandler` deadlocks permanently once a child writes more than the ~64KB pipe buffer (a `git status` on a large dirty repo did exactly that).

- **File I/O that can run at launch or in bulk runs off the main actor.** `TranscriptReader.parse` is `nonisolated static`, executed via `Task.detached(.utility)`, with a single MainActor `apply` step. Per-session refreshes are chained (`chains[id]`) so the byte-offset cursor is never advanced by two reads at once. Copy that shape — pure off-actor function returning a value struct, one isolated apply — for any new bulk I/O.

- **Timers are owned, invalidated in `stop()`/`deinit`, and hop to the main actor via `Task { @MainActor in … }`.** A repeating timer holding a strong self reference keeps the object alive forever; both `SessionStore` and `EventLogTailer` use `[weak self]`.

- **DispatchSource + file descriptor lifetimes: close the fd in `setCancelHandler`, never right after `cancel()`.** `cancel()` is asynchronous; the source can still touch the descriptor. Exemplar: `EventLogTailer.detachFile()`.

- **Blocking syscalls (`proc_listallpids` scans) run in `Task.detached`,** with results hopping back via `MainActor.run`. Exemplar: `SessionStore.countUntrackedProcesses()`.

## Verification

1. `swift build` — zero warnings tolerated in touched files.
2. Anything touching the tailer or transcript-reader paths: `swift run` against a live log and confirm events still arrive (the DispatchSource path only exercises at runtime).
