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
                                     ├──▶ TranscriptReader (off-main JSONL parse → tokens, model, last line)
                                     ├──▶ Notifier (transitions + context alarm)
                                     ▼
                     MenuBarExtra popover (SessionListView / SessionRowView)
                                     │ user clicks
                                     ▼
                    ITermFocus (AppleScript) · RowActions (editor/GitHub/Linear/…)
```

## Modules

| Module | Owns | Key seam |
|---|---|---|
| `App` | Composition root (`ArgusController`), wiring, config application | Closure callbacks — no DI framework |
| `hooks/argus-hook.sh` | Event capture inside Claude Code sessions | The JSONL schema (additive-only) |
| `EventLogTailer` | Tailing the daily log, replay, rollover, pruning | `onReplay` / `onEvent` |
| `SessionStore` | The state machine, live/history partition, stall & liveness sweep | `apply(_:)` + pure `targetStatus` |
| `Liveness` | Process identity `(pid, start time)`, CLI scan, staleness fallbacks | Pure statics |
| `TranscriptReader` | Incremental transcript parse (off-main), cost estimate | `parse` (pure) / `apply` (MainActor) |
| `ModelCatalog` | The one model table: context windows + pricing | Longest-prefix `entry(for:)` |
| `Notifier` | macOS notifications, debounce, context alarm latch | `transition` / `checkContext` |
| `RowActions` | Everything a row can do beyond focus | One object injected into views |
| `ITermFocus` | AppleScript bridge to iTerm2 | `Subprocess.run` + `Escape` |
| `Subprocess` / `Escape` | The only process spawner; escaping/validation | Used by everything that shells out |
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
| 2026-07 | iTerm2-only focus (no Terminal.app fallback) | iTerm's AppleScript sessions expose stable ids; Terminal's don't map to Claude sessions reliably |
| 2026-07 | `@Observable` + `@MainActor` classes, closure wiring | Small object graph; a DI framework or Combine would be pure overhead here |
| 2026-07 | Elapsed labels via `TimelineView`, not an observable clock | A ticking observable re-rendered the whole tree every second, popover open or not — battery cost for an all-day app |
| 2026-07 | One `Subprocess` helper with concurrent pipe drains | Two hand-rolled wrappers both deadlocked on >64KB output; the fix belongs in exactly one place |
| 2026-07 | Session/iTerm ids validated by shape, not escaped | They're hex-and-dash by construction; an allowlist is simpler and stronger than escaping arbitrary hostile input |
| 2026-07 | Zero external dependencies | Trust (the app watches private work), build speed, and nothing to go stale |
| 2026-07 | Swift 5 language mode on tools 6.0 | Strict concurrency migration is real work; honesty over a flag — see `steering/CONCURRENCY.md` |

## Open items

- **No CI.** The test suite runs locally only; nothing mechanically gates a PR.
- **Accessibility:** no `.accessibilityLabel`s, fixed point sizes, no Dynamic Type; status is color + word, which helps but hasn't been audited.
- **Pricing/window staleness:** `ModelCatalog` is hardcoded and will drift as models ship; costs are estimates by design.
- **Midnight rollover** re-materializes spanning sessions on their first event after the switch.
- **App icon** — the bundle ships without one.
- **Localization:** UI strings are inline English.
