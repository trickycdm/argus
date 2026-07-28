# Testing & Verification

> _Cross-cutting standard. The suite is Swift Testing (`@Suite`/`@Test`/`#expect`) in `Tests/ArgusTests`, run with `swift test` (~1s). The compile gate and this suite are the only mechanical enforcement in the repo — there is no CI._

## The pure-logic-extraction rule

**Every decision lives in a system-API-free function; the shell around it stays thin and gets a manual checklist instead.** This is what makes a GUI/permissions app tractable: `SessionStore.targetStatus`, `notificationNeedsYou`, `GitStatus.parse`/`webURL`, `ModelCatalog.entry`, `Format.*`, `Escape.*`, `TranscriptReader.parse`, `ITermFocus.uuid` are all pure and tested. If new logic is hard to test, extract the decision from the I/O first — don't reach for mocks.

## When to test

| Change | Required coverage |
|---|---|
| State machine, classification, parsing, formatting | Unit test in the matching suite — no exceptions |
| New model family / pricing | `ModelCatalog` entry + a longest-prefix assertion |
| Escaping / validation (`Escape`, hook script) | Unit test with hostile input (quotes, backslashes) + hook smoke test (`steering/EVENT_LOG_AND_HOOKS.md`) |
| Subprocess behaviour | `SubprocessTests` (includes the >64KB no-deadlock case) |
| UI layout / theme | No unit test — `swift run` and look at it |
| Notifications, TCC, iTerm focus | Cannot run headless — manual steps below |

## Suite conventions

- Suites that touch `@MainActor` state are `@MainActor @Suite`; anything mutating process-wide state (`Session.contextAlarmAt`) is `.serialized` and restores the value in a `defer`.
- The `event()` builder in `TestSupport.swift` is the one way to fabricate hook events.
- Tests assert observable behaviour through public API (`store.apply`, `store.live`), not internals.

## Manual verification (the untestable shell)

Run the subset your change touches, from the bundled app (`./scripts/bundle.sh && open dist/Argus.app`):

1. **Notifications:** trigger a needs-you transition; banner appears, clicking it focuses the tab.
2. **Focus/resume:** click a live row (focuses the exact iTerm pane); click a history row without an open tab (new tab runs `claude --resume`).
3. **Replay:** quit and relaunch with today's log populated — sessions rebuild, ended sessions stay in history, nothing resurrects as RUN.
4. **Install round-trip:** `install-hooks.sh` then `uninstall-hooks.sh` against a copy of `~/.claude/settings.json` leaves it as it started.

## The gate

A change is done when `swift build && swift test` is green and the relevant manual steps above have actually been run — state which ones in the summary, with what you saw.
