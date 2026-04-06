import Foundation
import Combine
import UserNotifications

final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [Session] = []
    /// Sessions filtered to the currently selected terminal type.
    /// Sessions without a terminal ID yet (just opened) are always shown.
    var visibleSessions: [Session] {
        let terminal = TerminalBridge.selected
        return sessions.filter { session in
            guard let rawId = session.terminalSessionId else { return true }
            return terminalIdMatchesType(rawId, terminal: terminal)
        }
    }

    private var wsTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let serverURL = URL(string: "ws://127.0.0.1:3737")!
    private var projectCounts: [String: Int] = [:]

    // MARK: - Connection

    func connect() {
        disconnect()
        urlSession = URLSession(configuration: .default)
        wsTask = urlSession?.webSocketTask(with: serverURL)
        wsTask?.resume()
        listen()
        startWindowStatePolling()
        startSessionDirectoryWatcher()
    }

    /// Clears all stale state and reconnects fresh.
    func refresh() {
        sessions.removeAll()
        projectCounts.removeAll()
        missingCounts.removeAll()
        finishedCounts.removeAll()
        connect()
        rescanActiveSessions()
        objectWillChange.send()
        log("Refresh: cleared all state and reconnected")
    }

    /// Called when the user switches terminal in the menu bar.
    func terminalChanged() {
        missingCounts.removeAll()
        rescanActiveSessions()
        objectWillChange.send()
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8) {
                    DispatchQueue.main.async {
                        self.handleMessage(data)
                    }
                }
                self.listen()
            case .failure:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.connect()
                }
            default:
                self.listen()
            }
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return }

        switch msg.type {
        case "snapshot":
            guard let serverSessions = msg.sessions else { return }
            for ss in serverSessions { upsertSession(from: ss) }
        case "update":
            guard let ss = msg.session else { return }
            upsertSession(from: ss)
        default:
            break
        }
    }

    private func upsertSession(from ss: ServerSession) {
        let state = SessionState(rawValue: ss.state) ?? .running
        if SessionState(rawValue: ss.state) == nil {
            log("Unknown server state: '\(ss.state)' for session \(ss.id)")
        }
        let terminalId = ss.terminalSessionId.flatMap { id in
            (id == "not a tty" || id.isEmpty) ? nil : id
        }
        let startDate: Date = {
            if let ms = ss.startedAt { return Date(timeIntervalSince1970: ms / 1000) }
            return Date()
        }()

        if let idx = sessions.firstIndex(where: { $0.id == ss.id }) {
            let oldState = sessions[idx].serverState
            sessions[idx].serverState = state
            sessions[idx].lastTool = ss.lastTool
            if let sid = terminalId { sessions[idx].terminalSessionId = sid }

            if oldState != state {
                notifyIfFinished(session: sessions[idx], newState: state)
            }
        } else {
            if state == .complete || state == .error {
                guard isSessionAlive(ss.id) else { return }
            }

            let label = deduplicatedLabel(project: ss.project)
            var session = Session(
                id: ss.id,
                project: ss.project,
                label: label,
                serverState: state,
                lastTool: ss.lastTool,
                terminalSessionId: terminalId,
                startedAt: startDate
            )
            session.pillColor = loadSavedColor(for: ss.id)
            sessions.append(session)
        }
    }

    /// Returns the PID for a session from ~/.claude/sessions/*.json, or nil if not found.
    private func pidForSession(_ sessionId: String) -> Int? {
        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: nil
        ) else { return nil }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  let sid = obj["sessionId"] as? String,
                  sid == sessionId else { continue }
            return pid
        }
        return nil
    }

    /// Returns true if the session's PID file exists and the process is still alive.
    private func isSessionAlive(_ sessionId: String) -> Bool {
        guard let pid = pidForSession(sessionId) else { return false }
        return kill(Int32(pid), 0) == 0
    }

    /// Returns true if the given PID has child processes (tool is actively executing).
    private static func hasChildProcesses(pid: Int) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return !data.isEmpty
    }

    // MARK: - Notifications

    private func notifyIfFinished(session: Session, newState: SessionState) {
        guard newState == .complete || newState == .error else { return }

        let content = UNMutableNotificationContent()
        content.title = newState == .complete ? "Session Complete" : "Session Error"
        content.body = session.label
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "session-\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Labeling

    private func deduplicatedLabel(project: String) -> String {
        let count = (projectCounts[project] ?? 0) + 1
        projectCounts[project] = count
        return count == 1 ? project : "\(project) #\(count)"
    }

    // MARK: - Local actions

    func toggleHidden(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isHidden.toggle()
    }

    func rename(id: String, to newName: String) {
        guard !newName.isEmpty,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].label = newName
    }

    func moveSession(id: String, toId: String) {
        guard let fromIdx = sessions.firstIndex(where: { $0.id == id }),
              let toIdx = sessions.firstIndex(where: { $0.id == toId }),
              fromIdx != toIdx else { return }
        let movingDown = fromIdx < toIdx
        let session = sessions.remove(at: fromIdx)
        if let newToIdx = sessions.firstIndex(where: { $0.id == toId }) {
            sessions.insert(session, at: movingDown ? newToIdx + 1 : newToIdx)
        }
    }

    func moveSessionUp(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        sessions.swapAt(idx, idx - 1)
    }

    func moveSessionDown(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }), idx < sessions.count - 1 else { return }
        sessions.swapAt(idx, idx + 1)
    }

    func setColor(id: String, color: PillColor) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].pillColor = color
        UserDefaults.standard.set(color.rawValue, forKey: "pillColor_\(id)")
    }

    private func loadSavedColor(for id: String) -> PillColor {
        guard let raw = UserDefaults.standard.string(forKey: "pillColor_\(id)"),
              let color = PillColor(rawValue: raw) else { return .none }
        return color
    }

    // MARK: - FSEvents-based session directory watcher

    private var sessionDirSource: DispatchSourceFileSystemObject?
    private var sessionDirFD: Int32 = -1

    /// Watches ~/.claude/sessions/ for file changes using kernel-level FSEvents.
    /// Only rescans when files are actually added/removed — no polling overhead.
    private func startSessionDirectoryWatcher() {
        stopSessionDirectoryWatcher()

        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")

        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        sessionDirFD = open(sessionDir.path, O_EVTONLY)
        guard sessionDirFD >= 0 else {
            log("FSEvents: failed to open sessions directory, falling back to timer")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: sessionDirFD,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.rescanActiveSessions()
        }

        source.setCancelHandler { [fd = sessionDirFD] in
            close(fd)
        }

        source.resume()
        sessionDirSource = source
        log("FSEvents: watching ~/.claude/sessions/")

        // Do one initial scan
        rescanActiveSessions()
    }

    private func stopSessionDirectoryWatcher() {
        sessionDirSource?.cancel()
        sessionDirSource = nil
        sessionDirFD = -1
    }

    // MARK: - Active session scanning

    /// Reads ~/.claude/sessions/*.json and ensures all live Claude processes have a pill.
    func rescanActiveSessions() {
        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  let sessionId = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String else { continue }

            guard kill(Int32(pid), 0) == 0 else { continue }
            guard !sessions.contains(where: { $0.id == sessionId }) else { continue }

            let terminalType = Self.detectTerminalType(for: pid)

            let startDate: Date = {
                if let ms = obj["startedAt"] as? Double {
                    return Date(timeIntervalSince1970: ms / 1000)
                }
                return Date()
            }()

            let project = (cwd as NSString).lastPathComponent
            let label = deduplicatedLabel(project: project)
            var session = Session(
                id: sessionId,
                project: project,
                label: label,
                serverState: .waiting,
                lastTool: nil,
                terminalSessionId: {
                    let tty = Self.ttyForPID(pid)
                    if terminalType == .iterm2 {
                        return "pending-\(tty ?? sessionId)"
                    }
                    return tty
                }(),
                startedAt: startDate
            )
            session.pillColor = loadSavedColor(for: sessionId)
            sessions.append(session)
        }
    }

    // MARK: - Focus cycling

    /// Focuses a specific session by its index in the visible list (for Control-Option-1-9).
    func focusSession(at index: Int) {
        let visible = visibleSessions
        guard index >= 0, index < visible.count else { return }
        let session = visible[index]
        if session.isHidden {
            TerminalBridge.showSession(terminalSessionId: session.terminalSessionId)
        }
        TerminalBridge.focusSession(terminalSessionId: session.terminalSessionId)
    }

    /// Cycles focus to the next visible session's terminal window.
    func focusNextSession() {
        let visible = visibleSessions
        guard !visible.isEmpty else { return }

        let currentIndex = UserDefaults.standard.integer(forKey: "lastFocusedIndex")
        let nextIndex = (currentIndex + 1) % visible.count
        UserDefaults.standard.set(nextIndex, forKey: "lastFocusedIndex")

        let session = visible[nextIndex]
        if session.isHidden {
            TerminalBridge.showSession(terminalSessionId: session.terminalSessionId)
        }
        TerminalBridge.focusSession(terminalSessionId: session.terminalSessionId)
    }

    /// Walks the process tree from a PID to detect if it's running inside iTerm2 or Terminal.app.
    private static func detectTerminalType(for pid: Int) -> TerminalType {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "ppid="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return .terminal }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return .terminal }
        var current = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1

        for _ in 0..<6 {
            guard current > 1 else { break }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-p", "\(current)", "-o", "ppid=,comm="]
            let pipe2 = Pipe()
            p.standardOutput = pipe2
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { break }
            let d = pipe2.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let line = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { break }

            if line.lowercased().contains("iterm") {
                return .iterm2
            }

            let parts = line.split(separator: " ", maxSplits: 1)
            current = Int(parts.first ?? "1") ?? 1
        }
        return .terminal
    }

    // MARK: - Window state polling

    private var pollTimer: Timer?
    private var missingCounts: [String: Int] = [:]
    /// Remove after 3 consecutive misses (5s each = 15s).
    private let missThreshold = 3
    private var finishedCounts: [String: Int] = [:]
    /// Remove finished sessions after 2 polls (5s each = 10s).
    private let finishedThreshold = 2

    /// Polling interval for window state checks.
    /// 5s is responsive enough for hide/show detection while keeping CPU usage low.
    private let windowPollInterval: TimeInterval = 5

    private func terminalIdMatchesType(_ rawId: String, terminal: TerminalType) -> Bool {
        switch terminal {
        case .iterm2:
            return rawId.contains("-") && !rawId.hasPrefix("/dev/")
        case .terminal:
            return rawId.hasPrefix("/dev/")
        }
    }

    private static func ttyForPID(_ pid: Int) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??" else { return nil }
        return "/dev/\(tty)"
    }

    /// Checks which TTYs currently have a `claude` process running.
    private static func activeClaudeTTYs() -> Set<String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "tty,comm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var ttys: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let comm = parts[1].trimmingCharacters(in: .whitespaces)
            if comm == "claude" {
                let tty = String(parts[0])
                ttys.insert("/dev/\(tty)")
            }
        }
        return ttys
    }

    private func removeDeadPIDSessions() {
        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        var deadSessions: Set<String> = []

        if let files = try? FileManager.default.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = obj["pid"] as? Int,
                      let sessionId = obj["sessionId"] as? String else { continue }
                if kill(Int32(pid), 0) != 0 {
                    deadSessions.insert(sessionId)
                }
            }
        }

        if !deadSessions.isEmpty {
            sessions.removeAll { session in
                let isDead = deadSessions.contains(session.id)
                if isDead {
                    missingCounts.removeValue(forKey: session.id)
                    finishedCounts.removeValue(forKey: session.id)
                }
                return isDead
            }
        }
    }

    private func startWindowStatePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: windowPollInterval, repeats: true) { [weak self] _ in
            self?.pollWindowStates()
        }
    }

    private func pollWindowStates() {
        // Only collect TTY sessions if any exist — avoids spawning ps when all sessions are iTerm2
        let ttySessionIds = sessions.compactMap { session -> (String, String)? in
            guard let rawId = session.terminalSessionId, rawId.hasPrefix("/dev/") else { return nil }
            return (session.id, rawId)
        }
        let hasTTYSessions = !ttySessionIds.isEmpty

        let terminal = TerminalBridge.selected
        TerminalBridge.pollWindowStates { [weak self] minimized, visible in
            // Only run the expensive ps check if we have TTY-based sessions
            let activeTTYs = hasTTYSessions ? Self.activeClaudeTTYs() : []
            var deadByTTY: Set<String> = []
            for (sessionId, tty) in ttySessionIds {
                if !activeTTYs.contains(tty) {
                    deadByTTY.insert(sessionId)
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }

                self.removeDeadPIDSessions()
                self.removeFinishedIfDead()
                self.checkQuestionMarkers()

                if !deadByTTY.isEmpty {
                    self.sessions.removeAll { deadByTTY.contains($0.id) }
                    for id in deadByTTY {
                        self.missingCounts.removeValue(forKey: id)
                        self.finishedCounts.removeValue(forKey: id)
                    }
                }

                let allKnown = minimized.union(visible)
                var toRemove: [String] = []

                for idx in self.sessions.indices {
                    let sessionId = self.sessions[idx].id
                    let rawId = self.sessions[idx].terminalSessionId

                    guard let rawId, rawId != "not a tty", !rawId.isEmpty,
                          !rawId.hasPrefix("pending-") else {
                        continue
                    }

                    guard self.terminalIdMatchesType(rawId, terminal: terminal) else {
                        continue
                    }

                    let uuid = terminal.sessionUUID(from: rawId)

                    if minimized.contains(uuid) {
                        self.sessions[idx].isHidden = true
                        self.missingCounts[sessionId] = 0
                    } else if visible.contains(uuid) {
                        self.sessions[idx].isHidden = false
                        self.missingCounts[sessionId] = 0
                    } else if !allKnown.isEmpty {
                        let count = (self.missingCounts[sessionId] ?? 0) + 1
                        self.missingCounts[sessionId] = count
                        if count >= self.missThreshold {
                            toRemove.append(sessionId)
                        }
                    }
                }

                for id in toRemove {
                    self.sessions.removeAll { $0.id == id }
                    self.missingCounts.removeValue(forKey: id)
                }

                NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
            }
        }
    }

    // MARK: - Question state detection

    private let questionThreshold: TimeInterval = 4

    /// Checks ~/.claudepills/waiting/ for marker files written by the PreToolUse hook.
    private func checkQuestionMarkers() {
        let waitingDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudepills/waiting")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: waitingDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        var pendingSessions: Set<String> = []
        let now = Date()

        for file in files {
            let sessionId = file.lastPathComponent
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  let timestamp = TimeInterval(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            let markerDate = Date(timeIntervalSince1970: timestamp)
            if now.timeIntervalSince(markerDate) >= questionThreshold {
                pendingSessions.insert(sessionId)
            }
        }

        for idx in sessions.indices {
            if pendingSessions.contains(sessions[idx].id) && sessions[idx].serverState == .running {
                // Before marking as question, check if a tool is actively executing.
                // If the Claude process has child processes (e.g. running Bash), the tool
                // is in progress — not waiting for user permission.
                if let pid = pidForSession(sessions[idx].id), Self.hasChildProcesses(pid: pid) {
                    // Tool is actively running — don't override to question
                } else {
                    sessions[idx].serverState = .question
                }
            } else if sessions[idx].serverState == .question && !pendingSessions.contains(sessions[idx].id) {
                sessions[idx].serverState = .running
            }
        }
    }

    /// Removes sessions whose PID is dead and server state is not running.
    private func removeFinishedIfDead() {
        var toRemove: [String] = []
        for session in sessions {
            if session.serverState == .running || session.serverState == .question { continue }
            if !isSessionAlive(session.id) {
                let count = (finishedCounts[session.id] ?? 0) + 1
                finishedCounts[session.id] = count
                if count >= finishedThreshold {
                    toRemove.append(session.id)
                }
            } else {
                finishedCounts.removeValue(forKey: session.id)
            }
        }
        for id in toRemove {
            sessions.removeAll { $0.id == id }
            missingCounts.removeValue(forKey: id)
            finishedCounts.removeValue(forKey: id)
        }
    }
}

extension Notification.Name {
    static let sessionsDidChange = Notification.Name("sessionsDidChange")
}
