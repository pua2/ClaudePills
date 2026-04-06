#!/usr/bin/env bash
# Claude Code hook → notify the ClaudePills server.
# Reads JSON from stdin, forwards to http://localhost:3737/update.
# Detects the active terminal and injects the appropriate session ID.
# Silently no-ops if the server is not running — never blocks Claude.

SERVER="http://127.0.0.1:3737/update"
PAYLOAD=$(cat)  # read full stdin

# Detect terminal and inject session identifier
TERM_SID=""
if [ -n "${ITERM_SESSION_ID:-}" ]; then
  TERM_SID="${ITERM_SESSION_ID}"
else
  # For Terminal.app and others: get the TTY of the parent Claude process.
  # Hooks run in a subprocess so `tty` returns "not a tty".
  # Instead, read the controlling TTY from the parent (Claude) process via ps.
  PARENT_TTY="$(ps -p "$PPID" -o tty= 2>/dev/null | tr -d ' ')"
  if [ -n "$PARENT_TTY" ] && [ "$PARENT_TTY" != "??" ]; then
    TERM_SID="/dev/${PARENT_TTY}"
  fi
fi

if [ -n "$TERM_SID" ]; then
  PAYLOAD=$(echo "$PAYLOAD" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['terminal_session_id'] = '${TERM_SID}'
json.dump(d, sys.stdout)
" 2>/dev/null || echo "$PAYLOAD")
fi

# Bail quickly if the server isn't up (1s timeout)
if ! curl -sf --max-time 1 -o /dev/null "http://127.0.0.1:3737/sessions" 2>/dev/null; then
  exit 0
fi

curl -sf --max-time 2 \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$SERVER" \
  > /dev/null 2>&1 || true

exit 0
