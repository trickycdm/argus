#!/bin/bash
# Argus hook — appends one JSON line per Claude Code hook event.
# Runs synchronously on every hook fire; must stay under ~10ms.
# No jq/sed/awk forks — field extraction is bash regex only.

EVENT="$1"
LOG_DIR="$HOME/Library/Application Support/Argus"

INPUT=$(cat)

# Captures the value in its JSON-escaped source form (escape sequences kept
# intact, closing quote found correctly even after \") — so printf-ing it back
# into the log line yields valid JSON by construction.
extract() {
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\""
  [[ $INPUT =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}

SID=$(extract session_id)
CWD=$(extract cwd)
TRANSCRIPT=$(extract transcript_path)

# One event-specific detail field; gated by event so a field name appearing
# inside prompt text can never be picked up from the wrong payload.
case "$EVENT" in
  Notification)
    # notification_type isn't guaranteed across CLI versions — fall back to
    # the human-readable message so the app can classify by text.
    DETAIL=$(extract notification_type)
    [[ -z $DETAIL ]] && DETAIL=$(extract message)
    DETAIL=${DETAIL:0:120}
    # Truncation can cut an escape pair in half; an odd trailing-backslash
    # run means exactly that — drop one to keep the JSON valid.
    T=${DETAIL##*[!\\]}
    (( ${#T} % 2 )) && DETAIL=${DETAIL%\\}
    ;;
  SessionStart) DETAIL=$(extract source) ;;
  SessionEnd)   DETAIL=$(extract reason) ;;
  *)            DETAIL="" ;;
esac

read -r STAMP DAY <<< "$(date '+%s %Y%m%d')"

# ITERM_SESSION_ID and TERM_PROGRAM come from the environment, not JSON —
# escape them ourselves. TERM_PROGRAM identifies the hosting terminal
# (e.g. ghostty) for sessions without an iTerm id.
IT=${ITERM_SESSION_ID//\\/\\\\}
IT=${IT//\"/\\\"}
TP=${TERM_PROGRAM//\\/\\\\}
TP=${TP//\"/\\\"}

mkdir -p "$LOG_DIR" 2>/dev/null
printf '{"v":2,"ts":%s,"event":"%s","detail":"%s","session_id":"%s","cwd":"%s","transcript":"%s","iterm":"%s","term":"%s","ppid":%s}\n' \
  "$STAMP" "$EVENT" "$DETAIL" "$SID" "$CWD" "$TRANSCRIPT" "$IT" "$TP" "${PPID:-0}" \
  >> "$LOG_DIR/events-$DAY.jsonl"

exit 0
