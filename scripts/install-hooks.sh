#!/bin/bash
# Installs Argus hooks into ~/.claude/settings.json.
# Safe: timestamped backup first, pure JSON merge, idempotent
# (replaces any existing entries referencing argus-hook.sh).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SCRIPT="$REPO_DIR/hooks/argus-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

[[ -x $HOOK_SCRIPT ]] || { echo "hook script missing or not executable: $HOOK_SCRIPT" >&2; exit 1; }

if [[ -f $SETTINGS ]]; then
  BACKUP="$SETTINGS.bak-$(date +%s)"
  cp "$SETTINGS" "$BACKUP"
  echo "backup: $BACKUP"
else
  # First-time Claude Code users may not have a settings file yet.
  mkdir -p "$(dirname "$SETTINGS")"
  printf '{}\n' > "$SETTINGS"
  echo "created: $SETTINGS"
fi

HOOK_SCRIPT="$HOOK_SCRIPT" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os

hook_script = os.environ["HOOK_SCRIPT"]
settings_path = os.environ["SETTINGS"]
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "Stop", "SessionEnd"]

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
for event in events:
    entries = hooks.setdefault(event, [])
    # Drop any previous Argus entries, then append the current one.
    entries[:] = [e for e in entries
                  if not any("argus-hook.sh" in h.get("command", "")
                             for h in e.get("hooks", []))]
    entries.append({"hooks": [{"type": "command",
                               "command": f"{hook_script} {event}"}]})

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"installed Argus hooks for: {', '.join(events)}")
PY

echo "done — running Claude sessions pick up hooks on their next session start"
