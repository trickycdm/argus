# Architecture

> Descriptive reference — the map is the root [`CLAUDE.md`](../CLAUDE.md); prescriptive rules live in [`../steering/`](../steering).

## The pipeline

```
Claude Code lifecycle events
        │  (7 hook points)
        ▼
hooks/argus-hook.sh ──▶ ~/Library/Application Support/Argus/events-YYYYMMDD.jsonl
                                     │ tail (DispatchSource + 2s poll)
                                     ▼
                              EventLogTailer
                                     │ HookEvent
                                     ▼
                               SessionStore ◀── Liveness (pid + start-time identity)
                                     │ state machine: 7 statuses
                                     ├──▶ TranscriptReader (off-main JSONL parse → tokens, model, last line, open background tasks)
                                     ├──▶ Notifier (transitions + context alarm)
                                     ▼
                     MenuBarExtra popover (SessionListView / SessionRowView)
                                     │ user clicks
                                     ▼
              TerminalFocus → ITermFocus / GhosttyFocus (AppleScript)
                            · RowActions (editor/GitHub/Linear/…)
```

## Modules

| Module | Owns | Key seam |
|---|---|---|
| `App` | Composition root (`ArgusController`), wiring, config application | Closure callbacks — no DI framework |
| `hooks/argus-hook.sh` | Event capture inside Claude Code sessions | The JSONL schema (additive-only) |
| `EventLogTailer` | Tailing the daily log, replay, rollover, pruning | `onReplay` / `onEvent` |
| `SessionStore` | The state machine, live/history partition, stall & liveness sweep | `apply(_:)` + pure `targetStatus` |
| `Liveness` | Process identity `(pid, start time)`, CLI scan, staleness fallbacks | Pure statics |
| `TranscriptReader` | Incremental transcript parse (off-main), cost estimate, background-task tracking | `parse` (pure) / `apply` (MainActor) |
| `ModelCatalog` | The one model table: context windows + pricing | Longest-prefix `entry(for:)` |
| `Notifier` | macOS notifications, debounce, context alarm latch | `transition` / `checkContext` |
| `RowActions` | Everything a row can do beyond focus | One object injected into views |
| `TerminalFocus` | Per-session backend dispatch (`TerminalApp` detect/config fallback) | `focus`/`resume` + shared `runOsascript` |
| `ITermFocus` / `GhosttyFocus` | AppleScript bridges (iTerm by session uuid; Ghostty by claude pid) | Pure script builders, tested without osascript |
| `Subprocess` / `Escape` | The only process spawner; escaping/validation | Used by everything that shells out |
| `Config` / `ConfigWriter` | Read config + non-clobbering raw-dict writer | `resolved(for:)` / `merged` (pure) |
| `HookInstall` | Hook detection in `~/.claude/settings.json`, installer location | Pure `isInstalled` / `installerCandidates` |
| `OnboardingWindowController` | First-run checklist window (AppKit) + `OnboardingModel` | `OnboardingFlow.needsOnboarding` (pure) |
| `Views/` | Flight Deck UI (`Deck` tokens in `Theme.swift`) | Pure rendering over `@Observable` state |

## Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07 | Hooks + log file, never terminal scraping | Scraping is fragile and invasive; hooks are the supported surface and the log doubles as replayable state |
| 2026-07 | Pure-bash hook, no forks, always exit 0 | Runs synchronously inside the user's sessions; must be unnoticeable and unable to break them |
| 2026-07 | Process identity = `(pid, kernel start time)`, never name | The Claude CLI sets its process title to a bare version string; names misidentify every session |
| 2026-07 | Replayed pids validated against event timestamps | A pid recycled after the original process died otherwise resurrects dead sessions on relaunch |
| 2026-07 | Two-axis status model (conversation × liveness) | "What is it doing" and "is it alive" fail independently; conflating them hid dead-but-idle sessions |
| 2026-07 | Stop means READY only after tool use | A bare Q&A turn isn't reviewable work; READY must mean "something to look at" |
| 2026-07 | Edge-triggered context alarm with hysteresis | Level-triggered alarms re-fire on every refresh; the 5-point band stops flapping around the threshold |
| 2026-07 | iTerm2-only focus (no Terminal.app fallback) — *superseded by per-session multi-backend below* | iTerm's AppleScript sessions expose stable ids; Terminal's don't map to Claude sessions reliably |
| 2026-07 | Per-session terminal auto-detect (iTerm2 + Ghostty), config only as fallback | One global setting misroutes mixed usage; the hook already sees each session's environment |
| 2026-07 | Ghostty ended sessions always resume — no tab-open badge | Ghostty has no per-session identity that outlives the claude process (pid dies with it); honest degrade beats a wrong badge |
| 2026-07 | Config writer = raw-dict merge; `ArgusConfig` stays Decodable-only | An Encodable round-trip silently deletes keys it doesn't know (hand-added or from a newer Argus) |
| 2026-07 | Onboarding is an AppKit window, not a SwiftUI `Window` scene | On macOS 14 (our floor) scenes are created at launch; `.defaultLaunchBehavior(.suppressed)` is 15+ |
| 2026-07 | First-run gate is an Int `onboardingVersion`, recorded on any close | Bumping the version re-runs setup after material changes; recording on skip/close means it never nags |
| 2026-07 | `@Observable` + `@MainActor` classes, closure wiring | Small object graph; a DI framework or Combine would be pure overhead here |
| 2026-07 | Elapsed labels via `TimelineView`, not an observable clock | A ticking observable re-rendered the whole tree every second, popover open or not — battery cost for an all-day app |
| 2026-07 | One `Subprocess` helper with concurrent pipe drains | Two hand-rolled wrappers both deadlocked on >64KB output; the fix belongs in exactly one place |
| 2026-07 | Session/iTerm ids validated by shape, not escaped | They're hex-and-dash by construction; an allowlist is simpler and stronger than escaping arbitrary hostile input |
| 2026-07 | Zero external dependencies | Trust (the app watches private work), build speed, and nothing to go stale |
| 2026-07 | Swift 5 language mode on tools 6.0 | Strict concurrency migration is real work; honesty over a flag — see `steering/CONCURRENCY.md` |
| 2026-07 | Background tasks tracked via transcript markers, not hooks or process scans | No hook fires at background completion (verified live; Pre/PostToolUse brackets the *launch*); transcript receipts carry structured ids and task-notifications close them. Process-tree scanning (shell-snapshot children of the session pid) works but is shells-only — kept as the fallback plan if the unstable transcript format drifts |

## Open items

- **No CI.** The test suite runs locally only; nothing mechanically gates a PR.
- **Accessibility:** no `.accessibilityLabel`s, fixed point sizes, no Dynamic Type; status is color + word, which helps but hasn't been audited.
- **Pricing/window staleness:** `ModelCatalog` is hardcoded and will drift as models ship; costs are estimates by design.
- **Midnight rollover** re-materializes spanning sessions on their first event after the switch.
- **Localization:** UI strings are inline English.
