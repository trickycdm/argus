# Event Log & Hooks

> _The data backbone: `hooks/argus-hook.sh` → daily JSONL log → `EventLogTailer` → `SessionStore` → `TranscriptReader`. Every rule exists because the hook runs inside the user's Claude Code sessions — a bug here doesn't break Argus, it breaks the user's real work._

## The hook contract

- **The hook always `exit 0`s, stays pure-bash (no jq/sed/awk forks), and must stay fast (~10ms).** It runs synchronously on every Claude Code lifecycle event; a slow or failing hook degrades every session on the machine. Never add a fork, a network call, or a nonzero exit path.
- **Field extraction keeps values in their JSON-escaped source form.** The `extract()` regex captures escape sequences intact, so printing them back into the log line yields valid JSON by construction. Values from the *environment* (`ITERM_SESSION_ID`, `TERM_PROGRAM`) are escaped explicitly. If you touch the escaping, re-run the hostile-input smoke tests (quotes, backslashes, truncation landing mid-escape — see Verification).
- **`detail` is gated by event name** so a field name appearing inside prompt text can never be picked up from the wrong payload. Keep the gate when adding events.

## The log

- **Schema changes are additive-only.** One JSON object per line: `v, ts, event, detail, session_id, cwd, transcript, iterm, term (v2+), ppid`. Old app versions must keep decoding new hook output and vice versa — bump `v` and add nullable fields (`HookEvent` decodes them as optionals); never rename or repurpose one. `term` carries raw `TERM_PROGRAM`; classification into a `TerminalApp` is app-side (`TerminalApp.detect`), and an iTerm id always outranks `term` because tmux overwrites `TERM_PROGRAM`.
- **Daily files (`events-YYYYMMDD.jsonl`), pruned after 7 days** — at start and on midnight rollover. The log is append-only; the tailer treats a shrinking file as recreated and starts over.
- **Malformed lines are skipped and logged, never fatal.** The log is written by shell code fed untrusted input; the reader's tolerance is the safety net.

## Replay semantics

- **On start, the app rebuilds all state by replaying yesterday's file then today's** (`quiet: true` — no notifications for old transitions). Two days, because sessions routinely outlive midnight and one parked at an idle prompt emits nothing to re-announce itself — a today-only replay makes every overnight session invisible with no recovery but restarting it. Only today's file is tailed; yesterday's is read once and closed.
- **`history` is a today-only view.** `SessionStore.pruneHistoryBeforeToday` runs on every liveness sweep and drops rows that ended before midnight — both yesterday's sessions that the widened replay retired, and rows the app watched end while running through the night. Pruning forgets the session id, so a straggling event earns a fresh row rather than resurrecting a delisted one.
- **Fork subagents are dropped, never shown**, by their own declaration: `SessionStart` with `source == "fork"`. Their rows would read as duplicates of the session they forked from; they surface on that row's BG chip instead.
- **Never *suppress* a session because of its parent process.** The daemon's spare-pty pool (`claude bg-spare`) parents forks and human-driven sessions from the same pid — a claude parent says nothing about whether anyone is at the keyboard, and treating it as proof of infrastructure silently discards real sessions, permission prompts included. `Liveness.hasClaudeCLIParent` exists only to keep the daemon's own subprocesses out of the untracked-CLI scan, so a pool-hosted session is counted once under the pid its hook events report.
- **Do use the process tree to *attribute* a session.** `Liveness.owningSessionPid` walks a session's claude ancestry (`bg-spare → bg-pty-host → daemon → terminal`) to the top-level CLI that owns it; a terminal session resolves to itself. When that owner is another tracked session, the row nests beneath it (`SessionStore.owner(of:)`) rather than standing beside it — a pool-hosted agent and the terminal that launched it are one session's work, and side by side in the same repo they read as duplicates. An agent whose owner isn't tracked keeps a top-level row; nesting is presentation, never a reason to hide a session.
- **Replay retires dead sessions on its single liveness check** (`checkLiveness(retireOnFirstCheck:)`). The usual two-strike rule absorbs a transient `kill(2)` failure against a live process; applying it to replay would show every dead session in the log as live for the first sweep interval after launch.
- **A replayed pid is guilty until proven innocent.** `Liveness.validatedStartTime` rejects any pid whose kernel start time is *after* the event's timestamp — that pid was recycled by an unrelated process. Identity is always `(pid, start time)`, never a process name (the Claude CLI sets its title to a bare version string). A session without a validated pid falls back to transcript-staleness for liveness.

## Transcript enrichment

- **`TranscriptReader` keeps a per-session byte-offset cursor** and reads only new bytes; a shrunken transcript (resume/compaction) resets the cursor and the token totals. Consume only complete lines; leave the trailing partial for next time.
- **Sidechain (subagent) usage never updates `contextTokens`** — subagents have their own context window; only main-chain prompt size approximates occupancy.
- **Background tasks open only on structured receipt fields** (`toolUseResult.backgroundTaskId`; `agentId` + `"async_launched"`), **and close only on `<task-id>` tags in non-assistant lines** — assistant lines quote receipts and tags verbatim (tool inputs, echoed output), so content-text matching produces false opens/closes. Hooks can't replace this: nothing fires at background completion. Track ids and counts only; task prompts and output never leave the parser (privacy invariant).
- **Transcript closes are not guaranteed to arrive** — a completion can be delivered to another transcript (observed: a fork agent's copy got the parent's shell notifications). Shell tasks are therefore cross-checked against live shell child processes of the session pid (`Liveness.shellChildCount`, swept in `SessionStore.clearStaleShellTasks`); agent tasks have no process to check and rely on transcript closes alone.
- **`ModelCatalog` is the only model table.** Context windows and pricing live there with longest-prefix matching; adding a model family is one `Entry`. Never add a second model list or inline price.

## Verification

1. Smoke the hook with hostile input and validate the output line:
   `printf '%s' '{"session_id":"t","cwd":"/tmp/has \" quote","transcript_path":"","message":"say \"hi\" \\ done"}' | TERM_PROGRAM='has " quote\' ./hooks/argus-hook.sh Notification` then validate the appended line with `python3 -m json.tool` (read the file directly in Python). Use `printf '%s'`, never `echo`, anywhere in the pipeline — zsh's `echo` interprets backslash escapes and corrupts the input (or the line under test) before it's seen. Setting `HOME` to a scratch dir keeps test lines out of the live log; otherwise remove them afterwards.
2. `swift test` — the state machine, replay identity, and catalog rules are covered in `Tests/ArgusTests`.
3. Schema changes: replay yesterday's real log through `swift run` and confirm sessions rebuild.
