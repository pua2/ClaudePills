#!/usr/bin/env bash
# Installs ClaudePills hooks into ~/.claude/settings.json
# Backs up existing settings before modifying.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/notify.sh"
BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"

if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "Error: notify.sh not found at $HOOK_SCRIPT" >&2
  exit 1
fi

chmod +x "$HOOK_SCRIPT"

# Create settings file if it doesn't exist
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

# Back up
cp "$SETTINGS" "$BACKUP"
echo "Backed up settings to $BACKUP"

# Use Python to safely merge hooks into existing JSON
python3 - "$SETTINGS" "$HOOK_SCRIPT" <<'PYEOF'
import sys, json

settings_path = sys.argv[1]
hook_script = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

hook_cmd = ["bash", hook_script]

new_hooks = [
    {"matcher": "", "hooks": [{"type": "command", "command": hook_cmd}]}
]

# Merge: add hook entries for PreToolUse and Stop events
# Settings format: {"hooks": {"PreToolUse": [...], "Stop": [...]}}
if "hooks" not in settings:
    settings["hooks"] = {}

for event in ("PreToolUse", "Stop"):
    existing = settings["hooks"].get(event, [])

    # Check if already installed (avoid duplicates)
    already = any(
        any(h.get("command") == hook_cmd for h in entry.get("hooks", []))
        for entry in existing
    )

    if not already:
        existing.append({"matcher": "", "hooks": [{"type": "command", "command": hook_cmd}]})
        settings["hooks"][event] = existing
        print(f"  Added hook for {event}")
    else:
        print(f"  Hook for {event} already present, skipping")

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("Done.")
PYEOF
