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
    static let appVersion = "0.1.0"

    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let dockYKey = "dockPanelY"
    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var sessionObserver: Any?
    private var pillsHidden = false
    private var helpWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var autoUpdateTimer: Timer?

    private let autoUpdateCheckKey = "autoUpdateCheckEnabled"
    private let lastUpdateCheckKey = "lastAutoUpdateCheck"
    private let skippedUpdateSHAKey = "skippedUpdateSHA"

    /// Tracks a pending update the user hasn't installed yet.
    private var pendingUpdate: (repo: String, remoteSHA: String, commits: String)?

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let observer = sessionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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

        scheduleAutoUpdateCheck()
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
        if pillsHidden {
            if panel.isVisible { panel.orderOut(nil) }
        } else {
            if !panel.isVisible { panel.orderFrontRegardless() }
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
        if pillsHidden {
            let icon = AppIcon.generateGrayed(size: 36)
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.title = ""
            return
        }
        let count = SessionManager.shared.visibleSessions.count
        let icon = AppIcon.generate(size: 36)
        icon.size = NSSize(width: 18, height: 18)
        button.image = icon
        button.title = count > 0 ? " \(count)" : ""
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // --- Sessions ---
        let hideShowTitle = pillsHidden ? "Show Pills" : "Hide Pills"
        menu.addItem(NSMenuItem(title: hideShowTitle, action: #selector(togglePillsHidden), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Refresh Sessions", action: #selector(refresh), keyEquivalent: "r"))

        // --- Terminal ---
        menu.addItem(.separator())

        let terminalMenu = NSMenu()
        let autoTitle = TerminalBridge.isAutomatic
            ? "Automatic (\(TerminalBridge.selected.displayName))"
            : "Automatic"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(selectAutomatic), keyEquivalent: "")
        autoItem.state = TerminalBridge.isAutomatic ? .on : .off
        terminalMenu.addItem(autoItem)
        terminalMenu.addItem(.separator())
        for terminal in TerminalType.allCases {
            let item = NSMenuItem(title: terminal.displayName, action: #selector(selectTerminal(_:)), keyEquivalent: "")
            item.representedObject = terminal.rawValue
            if !TerminalBridge.isAutomatic && terminal == TerminalBridge.selected {
                item.state = .on
            }
            terminalMenu.addItem(item)
        }
        let terminalItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        terminalItem.submenu = terminalMenu
        menu.addItem(terminalItem)

        // --- Position ---
        let positionMenu = NSMenu()
        let currentSide = panel?.dockSide ?? .right
        let leftItem = NSMenuItem(title: "Left Side", action: #selector(selectLeftSide), keyEquivalent: "")
        leftItem.state = currentSide == .left ? .on : .off
        positionMenu.addItem(leftItem)
        let rightItem = NSMenuItem(title: "Right Side", action: #selector(selectRightSide), keyEquivalent: "")
        rightItem.state = currentSide == .right ? .on : .off
        positionMenu.addItem(rightItem)
        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        // --- Settings ---
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        let autoUpdateItem = NSMenuItem(title: "Auto Check for Updates", action: #selector(toggleAutoUpdateCheck), keyEquivalent: "")
        autoUpdateItem.state = isAutoUpdateEnabled ? .on : .off
        menu.addItem(autoUpdateItem)

        // --- Updates & Help ---
        menu.addItem(.separator())

        if pendingUpdate != nil {
            menu.addItem(NSMenuItem(title: "Update Available — Install Now", action: #selector(installPendingUpdate), keyEquivalent: "u"))
        } else {
            menu.addItem(NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "u"))
        }
        menu.addItem(NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Help", action: #selector(showHelp), keyEquivalent: "?"))
        menu.addItem(NSMenuItem(title: "Copy Debug Info", action: #selector(copyDebugInfo), keyEquivalent: "d"))

        // --- Quit ---
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

    @objc private func togglePillsHidden() {
        pillsHidden.toggle()
        updatePanelVisibility()
        updateMenuBarIcon()
        rebuildMenu()
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        if pillsHidden {
            let icon = AppIcon.generateGrayed(size: 36)
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.title = ""
        } else {
            let icon = AppIcon.generate(size: 36)
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            updateMenuBarBadge()
        }
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

    // MARK: - Debug info

    private func generateDebugInfo() -> String {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString
        let uptime = Int(processInfo.systemUptime)
        let uptimeStr = "\(uptime / 3600)h \((uptime % 3600) / 60)m"

        let terminal = TerminalBridge.selected
        let terminalMode = TerminalBridge.isAutomatic ? "Automatic (\(terminal.displayName))" : terminal.displayName
        let dockSide = panel?.dockSide.rawValue ?? "unknown"
        let launchAtLogin = SMAppService.mainApp.status == .enabled ? "ON" : "OFF"
        let sessions = SessionManager.shared.sessions
        let visible = SessionManager.shared.visibleSessions

        let sessionLines = sessions.map { s in
            let state = s.displayState.label
            let tool = s.lastTool.map { " (\($0))" } ?? ""
            let termId = s.terminalSessionId ?? "none"
            return "  - \(s.label): \(state)\(tool) [term: \(termId)]"
        }.joined(separator: "\n")

        // Read last 20 lines of log
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudepills/app.log").path
        var recentLogs = "(no logs)"
        if let logData = FileManager.default.contents(atPath: logPath),
           let logStr = String(data: logData, encoding: .utf8) {
            let lines = logStr.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(20)
            recentLogs = tail.joined(separator: "\n")
        }

        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: Date())

        return """
        === ClaudePills Debug Info ===
        Version: \(Self.appVersion)
        Timestamp: \(timestamp)
        macOS: \(osVersion)
        System Uptime: \(uptimeStr)

        --- Settings ---
        Terminal: \(terminalMode)
        Dock Side: \(dockSide)
        Pills Hidden: \(pillsHidden ? "YES" : "NO")
        Launch at Login: \(launchAtLogin)

        --- Sessions (\(sessions.count) total, \(visible.count) visible) ---
        \(sessionLines.isEmpty ? "  (none)" : sessionLines)

        --- Recent Logs ---
        \(recentLogs)
        """
    }

    @objc private func copyDebugInfo() {
        let info = generateDebugInfo()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        log("Debug info copied to clipboard")
    }

    @objc private func terminalDidChange() {
        rebuildMenu()
    }

    @objc private func refresh() {
        SessionManager.shared.refresh()
    }

    @objc private func restartServer() {
        log("Restarting server via launchctl")
        let plist = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/com.claudepills.server.plist"
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plist]
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()

        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["load", plist]
        load.standardError = FileHandle.nullDevice
        try? load.run()
        load.waitUntilExit()

        // Reconnect after a short delay to let the server start
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionManager.shared.refresh()
        }
        log("Server restarted")
    }

    private func stopServer() {
        let plist = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/com.claudepills.server.plist"
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plist]
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()
    }

    // MARK: - Auto update check

    private var isAutoUpdateEnabled: Bool {
        // Default to ON if never set
        if UserDefaults.standard.object(forKey: autoUpdateCheckKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoUpdateCheckKey)
    }

    @objc private func toggleAutoUpdateCheck() {
        let newValue = !isAutoUpdateEnabled
        UserDefaults.standard.set(newValue, forKey: autoUpdateCheckKey)
        log("Auto update check \(newValue ? "enabled" : "disabled")")
        if newValue {
            scheduleAutoUpdateCheck()
        } else {
            autoUpdateTimer?.invalidate()
            autoUpdateTimer = nil
        }
        rebuildMenu()
    }

    private func scheduleAutoUpdateCheck() {
        guard isAutoUpdateEnabled else { return }

        // Check on launch if at least 24 hours since last check
        let lastCheck = UserDefaults.standard.double(forKey: lastUpdateCheckKey)
        let now = Date().timeIntervalSince1970
        let dayInterval: TimeInterval = 24 * 60 * 60

        if now - lastCheck >= dayInterval {
            // Delay a few seconds so the app finishes launching
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.silentCheckForUpdates()
            }
        }

        // Schedule a repeating timer for every 24 hours
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: dayInterval, repeats: true) { [weak self] _ in
            self?.silentCheckForUpdates()
        }
    }

    /// Checks for updates silently — only shows UI if an update is available and not skipped.
    private func silentCheckForUpdates() {
        guard let repo = repoDirectory() else {
            log("Auto update: could not find repo directory")
            return
        }

        log("Auto-checking for updates in \(repo)")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateCheckKey)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            guard self.runGit(["fetch", "origin"], in: repo) != nil else {
                log("Auto update: fetch failed, skipping")
                return
            }

            let localHead = self.runGit(["rev-parse", "HEAD"], in: repo) ?? ""
            let remoteHead = self.runGit(["rev-parse", "origin/main"], in: repo) ?? ""

            guard localHead != remoteHead else {
                log("Auto update: already up to date")
                return
            }

            let skippedSHA = UserDefaults.standard.string(forKey: self.skippedUpdateSHAKey)
            let logOutput = self.runGit(["log", "--oneline", "HEAD..origin/main"], in: repo) ?? "(unknown changes)"

            DispatchQueue.main.async {
                // Always track the pending update so the menu item updates
                self.pendingUpdate = (repo: repo, remoteSHA: remoteHead, commits: logOutput)
                self.rebuildMenu()

                // Only show the alert if this version wasn't skipped
                if remoteHead != skippedSHA {
                    self.showUpdateAlert(repo: repo, remoteSHA: remoteHead, commits: logOutput)
                } else {
                    log("Auto update: version \(remoteHead.prefix(7)) was skipped by user")
                }
            }
        }
    }

    // MARK: - Check for updates

    /// Derives the repo directory from the server LaunchAgent plist.
    private func repoDirectory() -> String? {
        let plistPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/com.claudepills.server.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              args.count >= 2 else { return nil }
        // args[1] is like /.../ClaudePills/server/server.js → go up 2 levels
        return (args[1] as NSString).deletingLastPathComponent.deletingLastPathComponent
    }

    private func runGit(_ arguments: [String], in directory: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func checkForUpdates() {
        guard let repo = repoDirectory() else {
            showAlert(title: "Update Error", message: "Could not find ClaudePills repo. Is the server LaunchAgent installed?")
            return
        }

        log("Checking for updates in \(repo)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Fetch latest from remote
            guard self.runGit(["fetch", "origin"], in: repo) != nil else {
                DispatchQueue.main.async {
                    self.showAlert(title: "Update Error", message: "Could not reach GitHub. Check your internet connection.")
                }
                return
            }

            // Compare local HEAD vs remote main
            let localHead = self.runGit(["rev-parse", "HEAD"], in: repo) ?? ""
            let remoteHead = self.runGit(["rev-parse", "origin/main"], in: repo) ?? ""

            if localHead == remoteHead {
                DispatchQueue.main.async {
                    self.pendingUpdate = nil
                    self.rebuildMenu()
                    self.showAlert(title: "Up to Date", message: "You're running the latest version of ClaudePills.")
                }
                return
            }

            // Get list of new commits
            let logOutput = self.runGit(["log", "--oneline", "HEAD..origin/main"], in: repo) ?? "(unknown changes)"

            DispatchQueue.main.async {
                self.pendingUpdate = (repo: repo, remoteSHA: remoteHead, commits: logOutput)
                self.rebuildMenu()
                // Manual check always shows the alert (clears any skip for this SHA)
                self.showUpdateAlert(repo: repo, remoteSHA: remoteHead, commits: logOutput)
            }
        }
    }

    private func showUpdateAlert(repo: String, remoteSHA: String, commits: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "New changes:\n\n\(commits)\n\nInstall update? This will rebuild and restart ClaudePills."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Skip This Version")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            installUpdate(repo: repo)
        } else {
            UserDefaults.standard.set(remoteSHA, forKey: skippedUpdateSHAKey)
            log("User skipped version \(remoteSHA.prefix(7))")
        }
    }

    /// Installs a previously discovered pending update directly (no second alert).
    @objc private func installPendingUpdate() {
        guard let pending = pendingUpdate else { return }
        installUpdate(repo: pending.repo)
    }

    private func installUpdate(repo: String) {
        log("Installing update from \(repo)")
        pendingUpdate = nil
        UserDefaults.standard.removeObject(forKey: skippedUpdateSHAKey)
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Pull latest
            guard self.runGit(["pull", "origin", "main"], in: repo) != nil else {
                DispatchQueue.main.async {
                    self.showAlert(title: "Update Failed", message: "git pull failed.")
                }
                return
            }

            // Rebuild
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            build.arguments = ["build", "--package-path", "\(repo)/ClaudePills"]
            build.currentDirectoryURL = URL(fileURLWithPath: repo)
            build.standardError = FileHandle.nullDevice
            do { try build.run() } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "Update Failed", message: "Swift build failed: \(error.localizedDescription)")
                }
                return
            }
            build.waitUntilExit()
            guard build.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self.showAlert(title: "Update Failed", message: "Swift build exited with code \(build.terminationStatus).")
                }
                return
            }

            // Run install script to create new .app bundle
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/bin/bash")
            install.arguments = ["\(repo)/scripts/install-launchagent.sh"]
            install.currentDirectoryURL = URL(fileURLWithPath: repo)
            install.standardError = FileHandle.nullDevice
            do { try install.run() } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "Update Failed", message: "Install script failed: \(error.localizedDescription)")
                }
                return
            }
            install.waitUntilExit()

            DispatchQueue.main.async {
                log("Update installed, restarting")

                // Restart server
                self.restartServer()

                // Relaunch app via LaunchAgent
                let plist = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/com.claudepills.app.plist"
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["unload", plist]
                unload.standardError = FileHandle.nullDevice
                try? unload.run()
                unload.waitUntilExit()

                let load = Process()
                load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                load.arguments = ["load", plist]
                load.standardError = FileHandle.nullDevice
                try? load.run()

                // Quit current instance — LaunchAgent will start the new one
                NSApp.terminate(nil)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        stopServer()
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let terminalDidChange = Notification.Name("terminalDidChange")
}

private extension String {
    var deletingLastPathComponent: String {
        (self as NSString).deletingLastPathComponent
    }
}
