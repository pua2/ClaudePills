import AppKit
import Combine
import ServiceManagement
import SwiftUI
import Carbon.HIToolbox

private let logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudepills").path
    if !FileManager.default.fileExists(atPath: dir) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let path = dir + "/app.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    return FileHandle(forWritingAtPath: path)
}()

func log(_ msg: String) {
    let line = "[ClaudePills] \(msg)\n"
    fputs(line, stderr)
    if let data = line.data(using: .utf8) {
        logFile?.seekToEndOfFile()
        logFile?.write(data)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let dockYKey = "dockPanelY"
    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var sessionObserver: Any?
    private var autoHideEnabled = UserDefaults.standard.bool(forKey: "autoHidePanel")
    private var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        AppIcon.setAsAppIcon()
        clearStaleWaitingMarkers()
        setupPanel()
        setupStatusItem()
        SessionManager.shared.connect()
        SessionManager.requestNotificationPermission()
        AccessibilityManager.shared.start()
        TerminalBridge.startAutoDetect()
        registerGlobalHotkeys()

        // When auto-detect switches terminal, rebuild the menu to reflect it
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalDidChange),
            name: .terminalDidChange,
            object: nil
        )

        // Auto-hide panel when no sessions
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .sessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePanelVisibility()
        }

        // Observe session changes for auto-hide and menu bar badge
        SessionManager.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePanelVisibility()
                self?.updateMenuBarBadge()
            }
            .store(in: &cancellables)
    }

    // MARK: - Stale marker cleanup

    private func clearStaleWaitingMarkers() {
        let waitingDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudepills/waiting")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: waitingDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        log("Cleared \(files.count) stale waiting markers")
    }

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Auto-hide

    private func updatePanelVisibility() {
        guard autoHideEnabled else {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        let hasVisible = !SessionManager.shared.visibleSessions.isEmpty
        if hasVisible && !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !hasVisible && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Global hotkeys (⌃⌥C cycle, ⌃⌥1-9 jump)

    /// Virtual key codes for 1-9 on US keyboard layout.
    private static let digitKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    private func registerGlobalHotkeys() {
        let modifiers = UInt32(controlKey | optionKey)
        let signature = OSType(0x434C_4D4E) // "CLMN"

        // ID 1 = ⌃⌥C (cycle)
        let cycleID = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(kVK_ANSI_C), modifiers, cycleID, GetApplicationEventTarget(), 0, &ref) == noErr {
            hotkeyRefs.append(ref)
            log("Hotkey ⌃⌥C registered")
        }

        // IDs 10-18 = ⌃⌥1 through ⌃⌥9
        for (i, keyCode) in Self.digitKeyCodes.enumerated() {
            let digitID = EventHotKeyID(signature: signature, id: UInt32(10 + i))
            var digitRef: EventHotKeyRef?
            if RegisterEventHotKey(keyCode, modifiers, digitID, GetApplicationEventTarget(), 0, &digitRef) == noErr {
                hotkeyRefs.append(digitRef)
            }
        }
        log("Hotkeys ⌃⌥1-9 registered")

        // Single Carbon event handler for all hotkeys
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                DispatchQueue.main.async {
                    if hotKeyID.id == 1 {
                        SessionManager.shared.focusNextSession()
                    } else if hotKeyID.id >= 10, hotKeyID.id <= 18 {
                        let index = Int(hotKeyID.id - 10)
                        SessionManager.shared.focusSession(at: index)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    // MARK: - Floating panel

    private func setupPanel() {
        guard let screen = NSScreen.main else {
            log("ERROR: No main screen")
            return
        }

        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 260
        let panelHeight: CGFloat = 400

        let savedY = UserDefaults.standard.double(forKey: dockYKey)
        let y = savedY > 0 ? savedY : visible.midY - panelHeight / 2

        let sideRaw = UserDefaults.standard.string(forKey: "dockSide") ?? "right"
        let isRight = sideRaw != "left"
        let x = isRight ? visible.maxX - panelWidth : visible.minX

        let rect = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        panel = FloatingPanel(contentRect: rect)

        let dockView = DockView()
            .environmentObject(SessionManager.shared)

        let hostingView = NSHostingView(rootView: dockView)
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        log("Panel shown")
    }

    // MARK: - Menu bar status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let icon = AppIcon.generate(size: 36)
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        }

        rebuildMenu()
        updateMenuBarBadge()
    }

    private func updateMenuBarBadge() {
        guard let button = statusItem?.button else { return }
        let count = SessionManager.shared.visibleSessions.count
        let icon = AppIcon.generate(size: 36)
        icon.size = NSSize(width: 18, height: 18)
        button.image = icon
        button.title = count > 0 ? " \(count)" : ""
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Terminal picker
        let terminalHeader = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        terminalHeader.isEnabled = false
        menu.addItem(terminalHeader)

        // Automatic option
        let autoTitle = TerminalBridge.isAutomatic
            ? "Automatic (\(TerminalBridge.selected.displayName))"
            : "Automatic"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(selectAutomatic), keyEquivalent: "")
        autoItem.state = TerminalBridge.isAutomatic ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        // Manual terminal options
        for terminal in TerminalType.allCases {
            let item = NSMenuItem(title: terminal.displayName, action: #selector(selectTerminal(_:)), keyEquivalent: "")
            item.representedObject = terminal.rawValue
            if !TerminalBridge.isAutomatic && terminal == TerminalBridge.selected {
                item.state = .on
            }
            menu.addItem(item)
        }

        // Dock side
        menu.addItem(.separator())

        let sideHeader = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        sideHeader.isEnabled = false
        menu.addItem(sideHeader)

        let currentSide = panel?.dockSide ?? .right
        let leftItem = NSMenuItem(title: "Left Side", action: #selector(selectLeftSide), keyEquivalent: "")
        leftItem.state = currentSide == .left ? .on : .off
        menu.addItem(leftItem)

        let rightItem = NSMenuItem(title: "Right Side", action: #selector(selectRightSide), keyEquivalent: "")
        rightItem.state = currentSide == .right ? .on : .off
        menu.addItem(rightItem)

        // Toggles
        menu.addItem(.separator())

        let autoHideItem = NSMenuItem(title: "Auto-Hide Panel", action: #selector(toggleAutoHide), keyEquivalent: "")
        autoHideItem.state = autoHideEnabled ? .on : .off
        menu.addItem(autoHideItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Help", action: #selector(showHelp), keyEquivalent: "?"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudePills", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func selectAutomatic() {
        TerminalBridge.isAutomatic = true
        log("Terminal mode: Automatic")
        rebuildMenu()
    }

    @objc private func selectTerminal(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let terminal = TerminalType(rawValue: raw) else { return }
        TerminalBridge.isAutomatic = false
        TerminalBridge.selected = terminal
        log("Terminal changed to \(terminal.displayName)")
        SessionManager.shared.terminalChanged()
        rebuildMenu()
    }

    @objc private func selectLeftSide() {
        panel?.switchToSide(.left)
        rebuildMenu()
    }

    @objc private func selectRightSide() {
        panel?.switchToSide(.right)
        rebuildMenu()
    }

    @objc private func toggleAutoHide() {
        autoHideEnabled.toggle()
        UserDefaults.standard.set(autoHideEnabled, forKey: "autoHidePanel")
        rebuildMenu()
        updatePanelVisibility()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("Launch at Login disabled")
            } else {
                try SMAppService.mainApp.register()
                log("Launch at Login enabled")
            }
        } catch {
            log("Launch at Login toggle failed: \(error)")
        }
        rebuildMenu()
    }

    @objc private func showHelp() {
        if let existing = helpWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudePills Help"
        window.contentView = NSHostingView(rootView: HelpView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        helpWindow = window
    }

    @objc private func noop() {}

    @objc private func terminalDidChange() {
        rebuildMenu()
    }

    @objc private func refresh() {
        SessionManager.shared.refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let terminalDidChange = Notification.Name("terminalDidChange")
}
