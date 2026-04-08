#!/usr/bin/env bash
# Builds a proper .app bundle, then installs LaunchAgents for the server + app.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_JS="$REPO_DIR/server/server.js"
APP_BIN="$REPO_DIR/ClaudePills/.build/debug/ClaudePills"
PLIST_DIR="$HOME/Library/LaunchAgents"

# Resolve node — prefer Homebrew (Apple Silicon and Intel), fall back to PATH
NODE_BIN="$(command -v node)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
    [[ -x "$candidate" ]] && NODE_BIN="$candidate" && break
done
if [[ -z "$NODE_BIN" ]]; then
    echo "ERROR: node not found. Install Node.js first." >&2
    exit 1
fi
echo "Using node: $NODE_BIN"

# ---------------------------------------------------------------------------
# 1. Build the Swift binary if it doesn't exist
# ---------------------------------------------------------------------------
if [[ ! -f "$APP_BIN" ]]; then
    echo "Building ClaudePills binary..."
    swift build --package-path "$REPO_DIR/ClaudePills"
fi

# ---------------------------------------------------------------------------
# 2. Assemble ClaudePills.app in /Applications
# ---------------------------------------------------------------------------
APP_DIR="/Applications/ClaudePills.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

FRESH_INSTALL=false
if [[ ! -d "$APP_DIR" ]]; then
    FRESH_INSTALL=true
    echo "Installing ClaudePills to $APP_DIR..."
    mkdir -p "$MACOS" "$CONTENTS/Resources"
else
    echo "Updating ClaudePills at $APP_DIR..."
fi

# Update binary
cp "$APP_BIN" "$MACOS/ClaudePills"
chmod +x "$MACOS/ClaudePills"

# Write/update Info.plist
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claudepills.app</string>
    <key>CFBundleName</key>
    <string>ClaudePills</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudePills</string>
    <key>CFBundleExecutable</key>
    <string>ClaudePills</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>ClaudePills needs Accessibility access to watch terminal windows.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>ClaudePills needs to control terminal apps to focus, hide, and show session windows.</string>
</dict>
</plist>
PLIST

# Only generate icon on fresh install (it never changes)
if [[ "$FRESH_INSTALL" == "true" ]] || [[ ! -f "$CONTENTS/Resources/AppIcon.icns" ]]; then
    echo "Generating app icon..."
    ICONSET_DIR=$(mktemp -d)/ClaudePills.iconset
    mkdir -p "$ICONSET_DIR"

    swift - "$ICONSET_DIR" <<'SWIFT'
import AppKit
func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    let s = size
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        CGColor(red: 0.85, green: 0.40, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.95, green: 0.60, blue: 0.40, alpha: 1.0)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0])!
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.resetClip()
    let pillWidth = s * 0.52
    let pillHeight = s * 0.13
    let pillRadius = pillHeight / 2
    let centerX = s * 0.5
    let spacing = s * 0.19
    let pillConfigs: [(yCenter: CGFloat, opacity: CGFloat, xOffset: CGFloat)] = [
        (s * 0.32, 0.65, -s * 0.04),
        (s * 0.32 + spacing, 1.0, 0),
        (s * 0.32 + spacing * 2, 0.80, s * 0.04)
    ]
    let dotColors: [CGColor] = [
        CGColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 1.0),
        CGColor(red: 1.0, green: 0.82, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.35, green: 0.90, blue: 0.55, alpha: 1.0)
    ]
    for (i, config) in pillConfigs.enumerated() {
        let pillX = centerX - pillWidth / 2 + config.xOffset
        let pillY = config.yCenter - pillHeight / 2
        let pillRect = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: config.opacity))
        ctx.addPath(pillPath)
        ctx.fillPath()
        let dotRadius = pillHeight * 0.25
        let dotX = pillX + pillHeight * 0.5
        let dotY = config.yCenter
        ctx.setFillColor(dotColors[i])
        ctx.fillEllipse(in: CGRect(x: dotX - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    }
    image.unlockFocus()
    return image
}

let dir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (sz, name) in sizes {
    let img = generateIcon(size: CGFloat(sz))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
}
SWIFT

    mkdir -p "$CONTENTS/Resources"
    iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS/Resources/AppIcon.icns"
fi

# Ad-hoc code sign — only on fresh install to preserve TCC (Accessibility) permissions
if [[ "$FRESH_INSTALL" == "true" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "App bundle ready at $APP_DIR"

# ---------------------------------------------------------------------------
# 3. Install LaunchAgents
# ---------------------------------------------------------------------------
mkdir -p "$PLIST_DIR"

# Server LaunchAgent
cat > "$PLIST_DIR/com.claudepills.server.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudepills.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$SERVER_JS</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claudepills-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claudepills-server.log</string>
</dict>
</plist>
EOF

# App LaunchAgent — points into the .app bundle so Accessibility prefs can track it.
cat > "$PLIST_DIR/com.claudepills.app.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudepills.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$MACOS/ClaudePills</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claudepills-app.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claudepills-app.log</string>
</dict>
</plist>
EOF

echo ""
echo "Installed LaunchAgents."
echo "  Server: $PLIST_DIR/com.claudepills.server.plist"
echo "  App:    $PLIST_DIR/com.claudepills.app.plist"
echo ""

if [[ "$FRESH_INSTALL" == "true" ]]; then
    echo "ClaudePills has been added to /Applications."
    echo ""
    echo "To start now:"
    echo "  launchctl load $PLIST_DIR/com.claudepills.server.plist"
    echo "  launchctl load $PLIST_DIR/com.claudepills.app.plist"
    echo ""
    echo "Then open System Settings > Privacy & Security > Accessibility"
    echo "and toggle on 'ClaudePills'."
else
    echo "ClaudePills has been updated in /Applications."
    echo ""
    echo "To restart:"
    echo "  launchctl unload $PLIST_DIR/com.claudepills.app.plist"
    echo "  launchctl load $PLIST_DIR/com.claudepills.app.plist"
fi
