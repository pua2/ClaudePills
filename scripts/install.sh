#!/usr/bin/env bash
# One-command installer for ClaudePills.
# Usage: curl -fsSL https://raw.githubusercontent.com/pua2/ClaudePills/main/scripts/install.sh | bash
set -euo pipefail

REPO_URL="https://github.com/pua2/ClaudePills.git"
INSTALL_DIR="$HOME/.claudepills/repo"

echo ""
echo "  ClaudePills Installer"
echo "  ====================="
echo ""

# ---------------------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------------------
if ! command -v swift &>/dev/null; then
    echo "ERROR: Swift is required. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

if ! command -v node &>/dev/null && ! [[ -x /opt/homebrew/bin/node ]] && ! [[ -x /usr/local/bin/node ]]; then
    echo "ERROR: Node.js is required. Install via Homebrew:"
    echo "  brew install node"
    exit 1
fi

if ! command -v git &>/dev/null; then
    echo "ERROR: git is required. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Clone or update the repo
# ---------------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "Updating existing ClaudePills repo..."
    git -C "$INSTALL_DIR" pull origin main --ff-only
else
    echo "Cloning ClaudePills..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# ---------------------------------------------------------------------------
# 3. Build
# ---------------------------------------------------------------------------
echo "Building ClaudePills..."
swift build --package-path "$INSTALL_DIR/ClaudePills"

# ---------------------------------------------------------------------------
# 4. Install (app bundle + LaunchAgents)
# ---------------------------------------------------------------------------
bash "$INSTALL_DIR/scripts/install-launchagent.sh"

# ---------------------------------------------------------------------------
# 5. Start services
# ---------------------------------------------------------------------------
PLIST_DIR="$HOME/Library/LaunchAgents"

# Stop existing instances if running
launchctl unload "$PLIST_DIR/com.claudepills.server.plist" 2>/dev/null || true
launchctl unload "$PLIST_DIR/com.claudepills.app.plist" 2>/dev/null || true

sleep 1

launchctl load "$PLIST_DIR/com.claudepills.server.plist"
launchctl load "$PLIST_DIR/com.claudepills.app.plist"

echo ""
echo "  ClaudePills is now running!"
echo ""
echo "  You should see a pill icon in your menu bar."
echo "  If this is a fresh install, grant Accessibility permissions:"
echo "    System Settings > Privacy & Security > Accessibility > ClaudePills"
echo ""
