# ClaudePills — Developer Guide

Inherits all global rules from `/Users/pavanamin/Documents/git/CLAUDE.md`.

## What This Is

A floating macOS dock that shows live status pills for active Claude Code sessions. Each session gets a pill pinned to the screen edge with real-time status (running, waiting, needs-input, complete, error). Click a pill to focus that terminal window. Pairs with a small Node server + shell hooks that report session state.

- **Platform:** macOS 14+ (Sonoma) | **Stack:** Swift 5.9 + AppKit + Swift Package Manager | **Mode:** Floating accessory app + menu bar

## Architecture

```
main.swift → AppDelegate (NSApplicationDelegate, .accessory mode)
├── FloatingPanel (NSPanel, edge-pinned, click-through where appropriate)
│   └── DockView → [PillView ...]            ← session pills
├── MenuBarView (NSStatusItem)               ← session count badge, settings
├── HelpView                                  ← onboarding / install help
├── SessionManager (singleton)               ← list of Session, polling, IPC
├── Session (model)                          ← id, status, label, color, terminal pid
├── TerminalBridge + TerminalType            ← iTerm2 / Terminal.app focus + window control
├── AccessibilityManager                     ← AX permission, window manipulation
└── AppIcon                                   ← programmatic dock/menu icon

Companion (outside the Swift app):
- server/server.js — local Node server hooks talk to via HTTP
- hooks/install.sh, hooks/notify.sh — Claude Code SessionStart / Stop / Notification hooks
```

**Key rules:**
- App runs as `.accessory` (no Dock icon, menu bar only) — never `.regular`
- The floating panel must use `.nonactivatingPanel` style mask so clicking pills doesn't steal focus from the user's terminal
- Window management goes through `AccessibilityManager` — requires AX permission, handle the not-granted case gracefully
- All session state comes from the local Node server; the app does not talk to Claude Code directly
- Auto-update uses `git pull && make install` driven from inside the app — confirm the install path is `/Applications`

## File Map

| File | Responsibility |
|---|---|
| `Sources/ClaudePills/main.swift` | Entry point, `NSApplication` bootstrap |
| `Sources/ClaudePills/AppDelegate.swift` | App lifecycle, status bar, panel, login-item, updates |
| `Sources/ClaudePills/FloatingPanel.swift` | Edge-pinned `NSPanel` subclass — non-activating, draggable |
| `Sources/ClaudePills/DockView.swift` | SwiftUI/AppKit view containing the pills row |
| `Sources/ClaudePills/PillView.swift` | Individual pill — status indicator, label, color, click/right-click |
| `Sources/ClaudePills/MenuBarView.swift` | `NSStatusItem` menu — session count, settings, terminal type, edge |
| `Sources/ClaudePills/HelpView.swift` | Onboarding / install verification panel |
| `Sources/ClaudePills/SessionManager.swift` | Singleton — polls local server, owns `[Session]`, broadcasts changes |
| `Sources/ClaudePills/Session.swift` | Model — id, status enum, label, color, terminal pid, last update |
| `Sources/ClaudePills/TerminalBridge.swift` | AppleScript / AX bridge for iTerm2 + Terminal.app focus and window state |
| `Sources/ClaudePills/TerminalType.swift` | Enum — iTerm2 / Terminal.app / auto-detect |
| `Sources/ClaudePills/AccessibilityManager.swift` | AX permission check, window position/size manipulation |
| `Sources/ClaudePills/AppIcon.swift` | Programmatic icon rendering for menu bar + dock |
| **Outside Swift target:** | |
| `server/server.js` | Local HTTP server receiving status updates from Claude Code hooks |
| `hooks/install.sh` | Installs hook scripts into `~/.claude/settings.json` |
| `hooks/notify.sh` | Posts session state to the local server |
| `setup.sh` | One-shot installer — builds Swift app, sets up Node server + hooks |

## Build

`make` (in repo root) builds release, signs with Lumaru team if available, packages as `ClaudePills.app`, installs to `/Applications`. No CI — local builds are the only gate.

## Test Suite Structure

No test target yet. When added: pure-Swift `SessionManager` parsing logic should be tested first (it has no AppKit dependency).

## Bug Fixer Notes

- Pills not appearing → start with `SessionManager` polling loop and the local Node server (`server/server.js`)
- Click doesn't focus terminal → `TerminalBridge` (AppleScript permission) or `AccessibilityManager` (AX permission)
- Pills stuck at "Running" → `hooks/notify.sh` not firing; check `~/.claude/settings.json` hook config
- Status mismatch with reality → `SessionManager` polling interval vs. server cache TTL
- Floating panel steals focus → missing `.nonactivatingPanel` style mask in `FloatingPanel`
- Auto-update fails → install path or `git pull` permissions in `/Applications/ClaudePills.app`

## iOS Reviewer Focus

(Despite "iOS" in the name, this is macOS — checklist still mostly applies.)

- AppKit-specific: weak references between `NSPanel` and view models — easy to leak
- AppleScript / AX permission failure paths must be user-visible — never silent
- All disk and network I/O off the main thread (`URLSession`, `Process`)
- No retain cycles in `NotificationCenter` observers (`removeObserver` in deinit)

## Agents

Use the universal agents from root: `bug-fixer`, `ios-reviewer`, `testing` (when tests exist), `doc-updater`, `performance` (for menu-bar responsiveness audits).
