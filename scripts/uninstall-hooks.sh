#!/bin/bash
# Removes Argus hook entries from ~/.claude/settings.json (and only those).
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[[ -f $SETTINGS ]] || { echo "settings file not found: $SETTINGS" >&2; exit 1; }

BACKUP="$SETTINGS.bak-$(date +%s)"
cp "$SETTINGS" "$BACKUP"
echo "backup: $BACKUP"

SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os

settings_path = os.environ["SETTINGS"]
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event in list(hooks):
    hooks[event] = [e for e in hooks[event]
                    if not any("argus-hook.sh" in h.get("command", "")
                               for h in e.get("hooks", []))]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("Argus hooks removed")
PY
