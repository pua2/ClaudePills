import Foundation

enum TerminalType: String, CaseIterable {
    case iterm2 = "iterm2"
    case terminal = "terminal"

    var displayName: String {
        switch self {
        case .iterm2: "iTerm2"
        case .terminal: "Terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .iterm2: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        }
    }

    var appName: String {
        switch self {
        case .iterm2: "iTerm2"
        case .terminal: "Terminal"
        }
    }

    var supportsSessionTargeting: Bool { true }

    func sessionUUID(from raw: String) -> String {
        switch self {
        case .iterm2:
            if let idx = raw.firstIndex(of: ":") {
                return String(raw[raw.index(after: idx)...])
            }
            return raw
        case .terminal:
            return raw
        }
    }

    // MARK: - AppleScript generators

    func focusScript(sessionId: String) -> String {
        switch self {
        case .iterm2:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(sessionId)" then
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
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(sessionId)" then
                                set selected tab of w to t
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            """
        }
    }

    func hideScript(sessionId: String) -> String {
        switch self {
        case .iterm2:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(sessionId)" then
                                    set miniaturized of w to true
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            """
        case .terminal:
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(sessionId)" then
                                set miniaturized of w to true
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            """
        }
    }

    func showScript(sessionId: String) -> String {
        switch self {
        case .iterm2:
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(sessionId)" then
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
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(sessionId)" then
                                set miniaturized of w to false
                                set selected tab of w to t
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            """
        }
    }

    func pollScript() -> String {
        switch self {
        case .iterm2:
            return """
                tell application "iTerm2"
                    set output to ""
                    repeat with w in windows
                        set isMini to miniaturized of w
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                set output to output & (unique id of s) & ":" & isMini & linefeed
                            end repeat
                        end repeat
                    end repeat
                    return output
                end tell
            """
        case .terminal:
            return """
                tell application "Terminal"
                    set output to ""
                    repeat with w in windows
                        set isMini to miniaturized of w
                        repeat with t in tabs of w
                            set output to output & (tty of t) & ":" & isMini & linefeed
                        end repeat
                    end repeat
                    return output
                end tell
            """
        }
    }

    func newWindowScript() -> String {
        switch self {
        case .iterm2:
            return """
                tell application "iTerm2"
                    create window with default profile
                end tell
            """
        case .terminal:
            return """
                tell application "Terminal"
                    do script ""
                    activate
                end tell
            """
        }
    }
}
