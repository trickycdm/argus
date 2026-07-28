# Argus 👁

The hundred-eyed watchman for your Claude Code sessions. A native macOS menu bar app showing every running session at a glance: who's working, who's blocked waiting on you, who finished.

## How it works

```
Claude Code hooks ──▶ hooks/argus-hook.sh ──▶ ~/Library/Application Support/Argus/events-YYYYMMDD.jsonl
                                                              │
                                              Argus.app tails the log, rebuilds
                                              per-session state, enriches from
                                              transcripts, checks pid liveness
```

- **Hook script** (~40 lines of bash, <15ms, no dependencies) appends one JSON line per Claude Code lifecycle event: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification` (with `notification_type`, falling back to the message text), `Stop`, `SessionEnd`. It also captures `ITERM_SESSION_ID` (for click-to-focus) and `$PPID` (the claude process, for liveness).
- **The app** never scrapes terminals. All state comes from the event log + transcript files + liveness checks. A process is identified by `(pid, kernel start time)` — never by name, because the Claude CLI sets its process title to a bare version string.

## Status model

Two axes: what the conversation is doing, and whether the process is alive.
The UI is a "Flight Deck" instrument panel: each row leads with a context-window
ring gauge (amber at ≥65%, with a macOS notification on crossing — re-arms
below 60% after compaction) and carries an avionics-style annunciator
(HOLD / REVIEW / RUN / STALL / STBY).

| Dot | Status | Meaning |
|---|---|---|
| 🟠 | needs you | blocked mid-turn: permission prompt / elicitation / agent needs input |
| 🔵 | ready | turn finished after real work (used tools) — review it |
| 🟢 (pulsing) | working | UserPromptSubmit / tool activity |
| 🟡 | stalled | working but silent: 5 min without events (30 min inside a tool call, since long builds fire no hooks; transcript mtime also counts as activity) |
| ⚪ | idle | at the prompt, nothing pending (fresh/resumed session, or a bare Q&A turn) |
| 🔴 | dead | process gone without a clean `SessionEnd` (history) |
| ⚪ | ended | clean exit (history) |

The menu bar icon shows the blocked count (exclamation eye) or the ready count (badged eye) when nothing is blocked. A macOS notification fires when a session transitions to needs-you (60s per-session debounce); "Notify on turn end" also covers ready. Clicking a notification focuses the session's iTerm tab. Focusing a ready session acknowledges it back to standby, so ready-counts mean "unseen".

## Row actions

Right-click any session row: focus tab, open in editor, open on GitHub (derived from `git remote`), open in Linear (ticket id parsed from the branch name, e.g. `feat/ENG-123`, else a configured board URL), copy session id / resume command, mark reviewed, snooze notifications 1h, end session (SIGTERM, confirmed). Hovering a row reveals editor/GitHub/snooze shortcuts. Rows also show a git chip (`●dirty ↑ahead ↓behind`, refreshed when the popover opens).

Config: `~/.config/argus/config.json` — `editor` (app name for `open -a`, default Zed), `linearWorkspace` (linear.app/&lt;slug&gt;), `contextAlarm` (context-window alert threshold as a percent, default 65, clamped 10–95), and per-project `projects.<cwd>.{board,github}` overrides. A repo can override any of these with a `.argus.json` (top-level `editor`/`linearWorkspace`/`board`/`github`). Click a row to jump to that exact iTerm2 tab/pane. Rows show project name, git branch, time in current state, last assistant message, and token count / ~cost.

## Install

Requirements: macOS 14+, Swift toolchain (Xcode or Command Line Tools), `python3` (used once by the hook installer to merge JSON), and [iTerm2](https://iterm2.com) — click-to-focus and resume are iTerm2-only; there is no Terminal.app fallback.

```sh
./scripts/install-hooks.sh     # merges hooks into ~/.claude/settings.json (backup kept, idempotent)
./scripts/bundle.sh            # builds dist/Argus.app (ad-hoc signed)
open dist/Argus.app
```

On first launch, approve the notification permission prompt. On first row-click, approve the "Argus wants to control iTerm2" Automation prompt. Running Claude sessions pick up the hooks on their next session start.

For autostart: `cp -R dist/Argus.app /Applications/` and add it as a Login Item in System Settings.

To remove: `./scripts/uninstall-hooks.sh` and quit the app.

## Dev

```sh
swift run        # full UI + state machine; notifications fall back to NSLog (no bundle id)
```

Smoke-test the hook: `echo '{"session_id":"t","cwd":"/tmp","transcript_path":""}' | ./hooks/argus-hook.sh Stop`

## Limitations (v1)

- Sessions spanning midnight re-materialize on their first event after rollover.
- Cost is an estimate ("~$") from per-turn transcript usage and a hardcoded price map; treat `/cost` as authoritative.
- Claude Code only (adapters for other agent CLIs would slot in at the event-log layer).
- iTerm2 only for focus/resume (see Install requirements).

## License

MIT — see [LICENSE](LICENSE).
