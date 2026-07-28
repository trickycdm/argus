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

- **On start, the app rebuilds all state by replaying today's file** (`quiet: true` — no notifications for old transitions).
- **A replayed pid is guilty until proven innocent.** `Liveness.validatedStartTime` rejects any pid whose kernel start time is *after* the event's timestamp — that pid was recycled by an unrelated process. Identity is always `(pid, start time)`, never a process name (the Claude CLI sets its title to a bare version string). A session without a validated pid falls back to transcript-staleness for liveness.

## Transcript enrichment

- **`TranscriptReader` keeps a per-session byte-offset cursor** and reads only new bytes; a shrunken transcript (resume/compaction) resets the cursor and the token totals. Consume only complete lines; leave the trailing partial for next time.
- **Sidechain (subagent) usage never updates `contextTokens`** — subagents have their own context window; only main-chain prompt size approximates occupancy.
- **`ModelCatalog` is the only model table.** Context windows and pricing live there with longest-prefix matching; adding a model family is one `Entry`. Never add a second model list or inline price.

## Verification

1. Smoke the hook with hostile input and validate the output line:
   `printf '%s' '{"session_id":"t","cwd":"/tmp/has \" quote","transcript_path":"","message":"say \"hi\" \\ done"}' | TERM_PROGRAM='has " quote\' ./hooks/argus-hook.sh Notification` then validate the appended line with `python3 -m json.tool` (read the file directly in Python). Use `printf '%s'`, never `echo`, anywhere in the pipeline — zsh's `echo` interprets backslash escapes and corrupts the input (or the line under test) before it's seen. Setting `HOME` to a scratch dir keeps test lines out of the live log; otherwise remove them afterwards.
2. `swift test` — the state machine, replay identity, and catalog rules are covered in `Tests/ArgusTests`.
3. Schema changes: replay yesterday's real log through `swift run` and confirm sessions rebuild.
