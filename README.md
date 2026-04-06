# ClaudePills

A floating macOS dock that shows live status pills for your Claude Code sessions. See at a glance which sessions are running, waiting, or need input — without switching windows.

## What it does

- **Floating pills** on the screen edge — one per active Claude Code session
- **Live status**: spinner (running), pulse (waiting), ? (needs input), checkmark (done)
- **Click to focus** any session's terminal window instantly
- **Hide/show** terminal windows from the pill (no Dock clutter)
- **Color-code** and rename pills to organize parallel sessions
- **Global hotkeys**: `Ctrl+Option+C` to cycle sessions, `Ctrl+Option+1-9` to jump
- **Notifications** when sessions complete or error
- **Auto-detect** iTerm2 and Terminal.app
- **Menu bar icon** with active session count

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ (comes with Xcode or Command Line Tools)
- Node.js 18+

## Quick Start

```bash
git clone https://github.com/pua2/ClaudePills.git
cd ClaudePills
./setup.sh
```

The setup script builds the app, installs hooks, creates the app bundle in `~/Applications`, and starts everything.

After setup, grant Accessibility permission:
**System Settings > Privacy & Security > Accessibility > toggle ON "ClaudePills"**

## How it works

ClaudePills has three parts:

1. **Hook** (`hooks/notify.sh`) — Claude Code calls this on every tool use and stop event, sending session state to the local server
2. **Server** (`server/server.js`) — lightweight Node.js WebSocket relay that tracks session state
3. **App** (`ClaudePills/`) — native macOS Swift app that connects to the server and renders floating pills

All communication is local (`127.0.0.1:3737`). Nothing leaves your machine.

## Usage

| Action | How |
|---|---|
| Focus a session | Click its pill |
| Rename | Double-click the pill |
| Set color | Right-click > Color |
| Hide/show terminal | Click the `−` / `□` button on hover |
| Reorder | Drag pills up/down |
| New terminal | Click `+` at the bottom |
| Cycle sessions | `Ctrl+Option+C` |
| Jump to session | `Ctrl+Option+1` through `9` |
| Move dock to other side | Menu bar icon > Position |

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.claudepills.server.plist
launchctl unload ~/Library/LaunchAgents/com.claudepills.app.plist
rm ~/Library/LaunchAgents/com.claudepills.*.plist
rm -rf ~/Applications/ClaudePills.app
```

## Architecture

```
ClaudePills/
├── ClaudePills/          # Swift Package — the macOS app
│   ├── Package.swift
│   └── Sources/ClaudePills/
├── server/               # Node.js WebSocket relay server
├── hooks/                # Claude Code hook scripts
├── scripts/              # LaunchAgent installer
├── demo/                 # Web-based interactive mockup (dev only)
└── setup.sh              # One-command setup
```
