import Foundation
import SwiftUI

enum SessionState: String, Codable, Equatable {
    case running
    case waiting
    case question
    case complete
    case hidden
    case error

    var label: String {
        switch self {
        case .running:  "Running"
        case .waiting:  "Waiting for input"
        case .question: "Needs input"
        case .complete: "Complete"
        case .hidden:   "Window hidden"
        case .error:    "Error"
        }
    }
}

enum PillColor: String, CaseIterable {
    case none
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case pink

    var displayName: String {
        switch self {
        case .none: "Default"
        default: rawValue.capitalized
        }
    }

    var emoji: String {
        switch self {
        case .none:   "○"
        case .red:    "🔴"
        case .orange: "🟠"
        case .yellow: "🟡"
        case .green:  "🟢"
        case .cyan:   "🩵"
        case .blue:   "🔵"
        case .purple: "🟣"
        case .pink:   "🩷"
        }
    }

    var color: Color? {
        switch self {
        case .none:   nil
        case .red:    Color(red: 0.97, green: 0.30, blue: 0.30)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.20)
        case .yellow: Color(red: 1.0, green: 0.82, blue: 0.20)
        case .green:  Color(red: 0.29, green: 0.87, blue: 0.49)
        case .cyan:   Color(red: 0.25, green: 0.80, blue: 0.90)
        case .blue:   Color(red: 0.36, green: 0.58, blue: 1.0)
        case .purple: Color(red: 0.65, green: 0.40, blue: 0.95)
        case .pink:   Color(red: 0.95, green: 0.40, blue: 0.70)
        }
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    var project: String
    var label: String
    var serverState: SessionState
    var isHidden: Bool = false
    var lastTool: String?
    var terminalSessionId: String?
    var pillColor: PillColor = .none
    var startedAt: Date = Date()
    /// Timestamp of the last server update (hook event) for this session.
    var lastServerUpdate: Date = Date()

    var displayState: SessionState {
        isHidden ? .hidden : serverState
    }

    /// Formatted elapsed time since session started.
    var elapsedString: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        let hours = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }
}

/// JSON payloads from the WebSocket server
struct ServerMessage: Decodable {
    let type: String
    let session: ServerSession?
    let sessions: [ServerSession]?
}

struct ServerSession: Decodable {
    let id: String
    let project: String
    let label: String
    let state: String
    let lastTool: String?
    let terminalSessionId: String?
    let startedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, project, label, state, lastTool, startedAt
        case terminalSessionId = "terminal_session_id"
    }
}
