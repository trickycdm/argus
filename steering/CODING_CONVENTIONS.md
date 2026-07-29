# Coding Conventions

> _Cross-cutting standard — applies to every file in `Sources/Argus`. Argus is a small observer app; the conventions exist to keep it small, honest, and safe to run all day next to real work._

## Structure

- **One type-cluster per file, named for its main type.** `SessionStore.swift` holds the store; `Subprocess.swift` holds the process helper and its `Escape` companion. Views live under `Views/`. Pure logic (`Format`, `ModelCatalog`, `GitStatus.parse`) lives at the top level so tests reach it without UI imports.
- **Zero external dependencies is a feature, not an accident.** System frameworks only. A dependency needs to clear a high bar: it must replace something we demonstrably get wrong, not merely save typing. The whole app builds in ~1s and that shapes the dev loop.
- **Extension seams stay where they are.** New agent-CLI adapters slot in at the event-log layer (write the same JSONL schema); new "open in X" actions go on `RowActions`. If a change needs a new singleton or a second subprocess wrapper, the seam is being broken.

## Error handling

- **No `try!`, no force-unwraps, no `as!` in `Sources/`.** Failures degrade: a malformed event line is skipped and logged, a missing transcript means no enrichment, a failed subprocess returns its status. The watchman must never crash because the thing it watches misbehaved.
- **Failures the user must act on go through `SessionStore.showAlert`** (the amber strip); everything else is `NSLog` with an `Argus:` prefix. Don't add new alert paths for failures the user can't do anything about.

## Logging & privacy

- **Never log transcript content, prompt text, or assistant messages.** Argus reads Claude Code transcripts — treat their content as the user's private working data. Log session ids, paths, event names, and counts only. The one place transcript text surfaces is the row's last-assistant-line, on screen, never in a log.
- **No telemetry, no network calls.** The app reads local files and spawns local processes; that's the entire I/O surface. Keep it that way — it's a trust property for an app that watches your coding sessions.

## Style

- Doc comments explain *why* and the constraint the code can't show ("`contains` is deliberate: the id property may or may not carry the prefix"), not what the next line does. Match the density already in the file.
- A doc comment asserting a *reason* goes stale as dangerously as code, and is trusted more. "A claude process parented by another claude is never a user terminal session" outlived the fact and shaped a wrong fix that discarded real sessions. Correct rationale comments in the same change that invalidates them — the rule the steering docs already get.
- Constants that tune behaviour (`stalledAfter`, debounce, retention) are `static let`s on the type that uses them, with the reasoning in a comment. The model/pricing table lives only in `ModelCatalog`.

## Verification

1. `swift build && swift test` — the suite runs in ~1s; there is no excuse for skipping it.
2. `grep -rn "try!\|as!" Sources/` stays empty.
