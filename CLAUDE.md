# Argus — Steering

The hundred-eyed watchman for Claude Code sessions: a macOS menu-bar app showing every running session at a glance — who's working, who's blocked on you, who finished. A bash hook appends one JSON line per lifecycle event; the app tails that log, rebuilds per-session state, enriches it from transcripts, and checks process liveness.

> Observer, not actor. Never scrapes terminals, never acts on a session without an explicit user click, never logs transcript content, makes no network calls.

This is the **canonical steering context** for the repo, loaded natively by Claude Code. The sibling `AGENTS.md` is a thin pointer back here. Keep this file at repo altitude — invariants, the map, and pointers; the doctrine behind the system is [`AI_NATIVE_REPO_STANDARDS.md`](AI_NATIVE_REPO_STANDARDS.md).

## Structure

```
Sources/Argus/
  App.swift            — composition root (ArgusController), AppDelegate, @main MenuBarExtra
  SessionStore.swift   — the state machine: apply/replay, live/history, stall & liveness sweep
  EventLogTailer.swift — tails the daily JSONL log (DispatchSource + 2s poll, rollover, pruning)
  TranscriptReader.swift — incremental off-main transcript parse; tokens, model, last line, cost, open background tasks
  Liveness.swift       — process identity (pid, kernel start time); CLI scan; staleness fallbacks
  ModelCatalog.swift   — THE model table: context windows + pricing, longest-prefix matched
  Models.swift         — SessionStatus, HookEvent (log schema), @Observable Session
  Notifier.swift       — UNUserNotificationCenter: transitions, context alarm latch, debounce
  Prefs.swift          — UserDefaults keys (notify toggle, onboarding version)
  Subprocess.swift     — the one process spawner + Escape (AppleScript/shell escaping, id validation)
  GitState.swift       — porcelain-v2 parse, remote → browsable URL
  TerminalFocus.swift  — TerminalApp (per-session detect) + backend dispatch, shared osascript runner
  ITermFocus.swift     — iTerm2 AppleScript bridge: focus by session uuid, list tabs, resume
  GhosttyFocus.swift   — Ghostty (1.3+) AppleScript bridge: focus by claude pid, resume
  RowActions.swift     — everything a row can do (editor/GitHub/Linear/copy/snooze/end)
  Config.swift         — config read + merge, and ConfigWriter (non-clobbering raw-dict writer)
  HookInstall.swift    — hook detection in ~/.claude/settings.json; installer location
  OnboardingWindowController.swift — first-run checklist window (AppKit) + OnboardingModel
  Format.swift         — pure display formatting
  Views/               — Flight Deck UI incl. OnboardingView; Theme.swift holds ALL color/font tokens (Deck)
Tests/ArgusTests/      — Swift Testing suite (~1s); event() builder in TestSupport.swift
hooks/argus-hook.sh    — the capture hook installed into ~/.claude/settings.json
scripts/               — bundle.sh (dist/Argus.app), install-/uninstall-hooks.sh, Info.plist, app icon (AppIcon.svg → make-icon.sh → AppIcon.icns)
```

Data flow, module table, decision log: [`docs/architecture.md`](docs/architecture.md).

## Load-Bearing Invariants

**Adoption status (read before trusting a bullet as enforced):** this repo has **no CI**. The compile gate and `swift test` are the only mechanical enforcement; everything below is convention held by review and by these docs.

- **The hook must never hurt the host session.** Always `exit 0`, pure bash, no forks, ~10ms. It runs inside the user's real Claude Code sessions (`steering/EVENT_LOG_AND_HOOKS.md`).
- **Log schema changes are additive-only** — old apps must decode new hook output and vice versa.
- **Observer, not actor.** The only process-affecting actions are explicit user clicks: End Session (confirmed SIGTERM) and Resume. Do not add auto-acting paths.
- **Privacy: never log transcript content, prompt text, or assistant messages** — session ids, paths, and counts only. No telemetry, no network (`steering/CODING_CONVENTIONS.md`).
- **Process identity is `(pid, kernel start time)`, never name** — and replayed pids are validated against event timestamps so a recycled pid can't resurrect a dead session (`Liveness.validatedStartTime`).
- **Malformed input never crashes:** skip bad JSONL lines, tolerate missing transcripts, degrade tier-by-tier. No `try!`/force-unwraps in `Sources/`.
- **All subprocess work goes through `Subprocess.run`** — never hand-rolled `Process`+`Pipe` (a pipe-buffer deadlock is why; `steering/CONCURRENCY.md`).
- **Untrusted values never reach AppleScript/shell unvalidated:** session/iTerm ids pass `Escape.isUUIDLike`; everything else goes through the `Escape` helpers (`steering/MACOS_PLATFORM.md`).
- **`ModelCatalog` is the single model table** (windows + pricing, longest-prefix). No second list, no inline prices.
- **Pure-logic extraction:** decisions live in system-API-free functions with tests; thin shells get manual checklists (`steering/TESTING_AND_VERIFICATION.md`).
- **Zero external dependencies** — system frameworks only, by design.

## Tooling

Requires macOS 14+, a Swift 6 toolchain, python3 (hook installer only), iTerm2 and/or Ghostty 1.3+ (focus/resume).

```sh
swift build && swift test        # the whole gate, ~1s; run it after every change
swift run                        # full UI; notifications fall back to NSLog (no .app bundle)
./scripts/bundle.sh              # dist/Argus.app (ad-hoc signed) — needed for notification/TCC testing
./scripts/install-hooks.sh       # merge hooks into ~/.claude/settings.json (backup kept, idempotent)
```

- `UNUserNotificationCenter` **crashes** outside a real `.app` bundle — all calls are gated on `Notifier.hasBundle`; test notification behaviour only from the bundled app.
- The hook's smoke test (hostile quotes/backslashes) is in `steering/EVENT_LOG_AND_HOOKS.md` — clean test lines out of the live log afterwards.
- Mic-free, but TCC still applies: the first row-click per terminal prompts for that app's Automation consent (keyed to the bundle id — don't change `CFBundleIdentifier` casually).

## Standards

Cross-cutting standards live in [`steering/`](steering) and are the authority for their topic — start there, don't re-derive conventions from the code:

- [`steering/CODING_CONVENTIONS.md`](steering/CODING_CONVENTIONS.md) — structure, error handling, logging + privacy, dependency policy.
- [`steering/CONCURRENCY.md`](steering/CONCURRENCY.md) — the MainActor model, subprocess rules, timer/fd lifecycles; **read before adding any timer, Process, or DispatchSource**.
- [`steering/EVENT_LOG_AND_HOOKS.md`](steering/EVENT_LOG_AND_HOOKS.md) — hook contract, schema evolution, replay semantics; **read before touching the hook or any parser**.
- [`steering/MACOS_PLATFORM.md`](steering/MACOS_PLATFORM.md) — menu-bar app shape, notifications, AppleScript/TCC, signing.
- [`steering/DESIGN_SYSTEM.md`](steering/DESIGN_SYSTEM.md) — Flight Deck tokens and color law; **new UI color = token, never a literal**.
- [`steering/TESTING_AND_VERIFICATION.md`](steering/TESTING_AND_VERIFICATION.md) — pure-logic-extraction rule, when-to-test table, manual checklists.

## Per-Module Steering

No module carries its own `CLAUDE.md` yet — the repo is small enough that this map covers it. Give a module one only when sessions repeatedly stumble there; grow steering with the code.

## Writing CLAUDE.md

`CLAUDE.md` documents what code can't tell you: architecture, conventions, invariants, the why behind non-obvious choices.

- **Don't duplicate code facts** (prices, hex values, signatures) — link to their authoritative home; copies drift.
- **Don't state aspirational architecture as current fact.** Nothing here is CI-enforced; mark targets as targets. Agents trust steering literally.
- **Keep every `CLAUDE.md` under 200 lines** — overflow goes to `steering/` or a nested file.
- Update the relevant steering doc in the same change that invalidates it. A stale steering doc is worse than none.

## Steering-Doc Convention

- **`CLAUDE.md` is canonical**; **`AGENTS.md` is a thin pointer** for tools that look for it.
- **`steering/` holds prescriptive standards; `docs/` holds descriptive reference** (architecture, decision log, open items).
- **Plans live in `plans/<YYYY-MM-DD>-<slug>/plan.md` + `worklog.md`** — local-only (gitignored) in this repo.
- **Grow with the code, prune drift** — fix docs the moment code contradicts them.
