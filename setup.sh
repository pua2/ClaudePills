#!/usr/bin/env bash
# ClaudePills — one-command setup
# Builds the app, installs hooks, starts everything.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== ClaudePills Setup ==="
echo ""

# ─── Prerequisites ────────────────────────────────────────────────────────────
echo "Checking prerequisites..."

if ! command -v swift &>/dev/null; then
    echo "ERROR: Swift not found. Install Xcode or Xcode Command Line Tools." >&2
    exit 1
fi

if ! command -v node &>/dev/null; then
    echo "ERROR: Node.js not found. Install via: brew install node" >&2
    exit 1
fi

SWIFT_VER=$(swift --version 2>&1 | head -1)
NODE_VER=$(node --version)
echo "  Swift: $SWIFT_VER"
echo "  Node:  $NODE_VER"
echo ""

# ─── 1. Build Swift app ──────────────────────────────────────────────────────
echo "Building ClaudePills..."
swift build --package-path "$REPO_DIR/ClaudePills" 2>&1 | tail -1
echo ""

# ─── 2. Install server dependencies ──────────────────────────────────────────
echo "Installing server dependencies..."
cd "$REPO_DIR/server" && npm install --silent
cd "$REPO_DIR"
echo ""

# ─── 3. Install hooks into Claude Code ───────────────────────────────────────
echo "Installing Claude Code hooks..."
bash "$REPO_DIR/hooks/install.sh"
echo ""

# ─── 4. Create app bundle + LaunchAgents ─────────────────────────────────────
echo "Creating app bundle and LaunchAgents..."
bash "$REPO_DIR/scripts/install-launchagent.sh"
echo ""

# ─── 5. Start services ───────────────────────────────────────────────────────
PLIST_DIR="$HOME/Library/LaunchAgents"

echo "Starting services..."
launchctl unload "$PLIST_DIR/com.claudepills.server.plist" 2>/dev/null || true
launchctl load "$PLIST_DIR/com.claudepills.server.plist"
echo "  Server started"

launchctl unload "$PLIST_DIR/com.claudepills.app.plist" 2>/dev/null || true
launchctl load "$PLIST_DIR/com.claudepills.app.plist"
echo "  App started"

echo ""
echo "=== Setup complete! ==="
echo ""
echo "ClaudePills is now running. You should see:"
echo "  - A pill icon in your menu bar"
echo "  - Floating pills on the right edge when Claude Code sessions are active"
echo ""
echo "Next steps:"
echo "  1. Open System Settings > Privacy & Security > Accessibility"
echo "     and toggle ON 'ClaudePills'"
echo "  2. Start a Claude Code session in your terminal — a pill will appear"
echo ""
echo "To open the app from Applications:"
echo "  open ~/Applications/ClaudePills.app"
