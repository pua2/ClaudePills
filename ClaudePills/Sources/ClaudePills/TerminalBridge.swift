import AppKit
import ApplicationServices
import Foundation

enum TerminalBridge {
    private static let terminalKey = "selectedTerminal"
    private static let autoKey = "terminalAutoDetect"

    /// Whether automatic terminal detection is enabled.
    static var isAutomatic: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    /// The terminal to use for polling and actions.
    /// In auto mode, returns the last-detected terminal.
    /// In manual mode, returns the user's explicit choice.
    static var selected: TerminalType {
        get {
            if let raw = UserDefaults.standard.string(forKey: terminalKey),
               let t = TerminalType(rawValue: raw) {
                return t
            }
            return .iterm2
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: terminalKey)
        }
    }

    /// Start observing app activations for auto-detect mode.
    static func startAutoDetect() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard isAutomatic else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }

            let matched: TerminalType?
            switch bundleId {
            case TerminalType.iterm2.bundleIdentifier:
                matched = .iterm2
            case TerminalType.terminal.bundleIdentifier:
                matched = .terminal
            default:
                matched = nil
            }

            if let terminal = matched, terminal != selected {
                selected = terminal
                log("Auto-detected terminal: \(terminal.displayName)")
                SessionManager.shared.terminalChanged()
                NotificationCenter.default.post(name: .terminalDidChange, object: nil)
            }
        }
    }

    // MARK: - Actions

    static func focusSession(terminalSessionId: String?) {
        let terminal = selected
        log("focusSession terminal=\(terminal.displayName) raw=\(terminalSessionId ?? "nil")")
        guard let raw = terminalSessionId, !raw.isEmpty, terminal.supportsSessionTargeting else {
            runOsascript("""
                tell application "\(terminal.appName)" to activate
            """)
            return
        }

        // For pending sessions, use the embedded TTY to find the iTerm session
        let script: String
        if raw.hasPrefix("pending-") {
            let tty = String(raw.dropFirst("pending-".count))
            guard tty.hasPrefix("/dev/") else {
                runOsascript("tell application \"\(terminal.appName)\" to activate")
                return
            }
            script = focusByTTYScript(terminal: terminal, tty: tty)
        } else {
            let sid = terminal.sessionUUID(from: raw)
            script = terminal.focusScript(sessionId: sid)
        }

        let bundleId = terminal.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: AppleScript selects the right tab/window
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            // Step 2: Bring the terminal app to front from any app
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleId
            ).first {
                app.activate()
            }
        }
    }

    static func hideSession(terminalSessionId: String?) {
        let terminal = selected
        log("hideSession terminal=\(terminal.displayName) raw=\(terminalSessionId ?? "nil")")
        guard let raw = terminalSessionId, !raw.isEmpty else { return }
        if raw.hasPrefix("pending-") {
            let tty = String(raw.dropFirst("pending-".count))
            guard tty.hasPrefix("/dev/") else { return }
            runOsascript(hideByTTYScript(terminal: terminal, tty: tty))
        } else {
            let sid = terminal.sessionUUID(from: raw)
            runOsascript(terminal.hideScript(sessionId: sid))
        }
    }

    static func showSession(terminalSessionId: String?) {
        let terminal = selected
        log("showSession terminal=\(terminal.displayName) raw=\(terminalSessionId ?? "nil")")
        guard let raw = terminalSessionId, !raw.isEmpty else { return }
        if raw.hasPrefix("pending-") {
            let tty = String(raw.dropFirst("pending-".count))
            guard tty.hasPrefix("/dev/") else { return }
            runOsascript(showByTTYScript(terminal: terminal, tty: tty))
        } else {
            let sid = terminal.sessionUUID(from: raw)
            runOsascript(terminal.showScript(sessionId: sid))
        }
    }

    static func createNewWindow() {
        runOsascript(selected.newWindowScript())
    }

    // MARK: - Polling

    static func pollWindowStates(completion: @escaping (Set<String>, Set<String>) -> Void) {
        let terminal = selected
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", terminal.pollScript()]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                completion([], [])
                return
            }

            // Read pipe data BEFORE waitUntilExit to avoid deadlock
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                completion([], [])
                return
            }

            var minimized: Set<String> = []
            var visible: Set<String> = []
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let id = String(parts[0])
                if parts[1] == "true" {
                    minimized.insert(id)
                } else {
                    visible.insert(id)
                }
            }
            completion(minimized, visible)
        }
    }

    // MARK: - TTY-based scripts (for pending sessions)

    private static func focusByTTYScript(terminal: TerminalType, tty: String) -> String {
        switch terminal {
        case .iterm2:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select t
                                    set index of w to 1
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            """
        case .terminal:
            return terminal.focusScript(sessionId: tty)
        }
    }

    private static func hideByTTYScript(terminal: TerminalType, tty: String) -> String {
        switch terminal {
        case .iterm2:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    set miniaturized of w to true
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            """
        case .terminal:
            return terminal.hideScript(sessionId: tty)
        }
    }

    private static func showByTTYScript(terminal: TerminalType, tty: String) -> String {
        switch terminal {
        case .iterm2:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    set miniaturized of w to false
                                    select t
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            """
        case .terminal:
            return terminal.showScript(sessionId: tty)
        }
    }

    // MARK: - Private

    static func runOsascript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", source]
            let errPipe = Pipe()
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    log("osascript ERROR (\(proc.terminationStatus)): \(errStr)")
                }
            } catch {
                log("osascript launch error: \(error)")
            }
        }
    }
}
