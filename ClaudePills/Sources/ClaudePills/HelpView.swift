import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(nsImage: AppIcon.generate(size: 64))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .cornerRadius(10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClaudePills")
                            .font(.system(size: 22, weight: .bold))
                        Text("v\(AppDelegate.appVersion)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Text("A floating panel that shows live status pills for your Claude Code sessions.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Divider()

                // Status Icons
                helpSection("Status Icons") {
                    statusRow(icon: "◌", color: Color(red: 0.36, green: 0.58, blue: 1.0), title: "Running", desc: "Claude is actively working — thinking, reading files, or running tools.")
                    statusRow(icon: "●", color: Color(red: 1.0, green: 0.72, blue: 0.16), title: "Waiting", desc: "Session is idle, waiting for your next message.")
                    statusRow(icon: "?", color: Color(red: 0.85, green: 0.55, blue: 1.0), title: "Needs Input", desc: "Claude is asking a question or waiting for permission to use a tool.")
                    statusRow(icon: "✓", color: Color(red: 0.29, green: 0.87, blue: 0.49), title: "Complete", desc: "Session has finished.")
                    statusRow(icon: "✕", color: Color(red: 0.97, green: 0.38, blue: 0.38), title: "Error", desc: "Session encountered an error.")
                    statusRow(icon: "−", color: Color(white: 0.55), title: "Hidden", desc: "Terminal window is minimized.")
                }

                Divider()

                // Interactions
                helpSection("Interactions") {
                    interactionRow(action: "Click pill", desc: "Focus that session's terminal window")
                    interactionRow(action: "Double-click pill", desc: "Rename the session")
                    interactionRow(action: "Right-click pill", desc: "Context menu — rename, set color, hide/show, reorder, close session")
                    interactionRow(action: "Drag pill vertically", desc: "Reorder pills in the panel")
                    interactionRow(action: "Drag the panel", desc: "Move it up or down along the screen edge")
                    interactionRow(action: "Click +", desc: "Open a new terminal window")
                }

                Divider()

                // Keyboard Shortcuts
                helpSection("Keyboard Shortcuts") {
                    shortcutRow(keys: "⌃⌥C", desc: "Cycle focus between sessions")
                    shortcutRow(keys: "⌃⌥1-9", desc: "Jump directly to session by position")
                }

                Divider()

                // Menu Bar
                helpSection("Menu Bar") {
                    tipRow("The menu bar icon shows the number of active sessions.")
                    tipRow("Switch between iTerm2 and Terminal.app, or let it auto-detect.")
                    tipRow("Dock the panel on the left or right edge of your screen.")
                    tipRow("Hide Pills hides the panel and grays out the menu bar icon. Click Show Pills to restore.")
                    tipRow("Restart Server wipes all stale sessions and reconnects fresh.")
                    tipRow("Check for Updates fetches the latest from GitHub and installs if available.")
                    tipRow("Quit also stops the background server.")
                    tipRow("Launch at Login starts ClaudePills when you log in.")
                }

                Divider()

                // Tips
                helpSection("Tips") {
                    tipRow("Pills appear as soon as you start claude in a terminal — no need to send a query first.")
                    tipRow("Color-code pills to visually group related sessions.")
                    tipRow("The elapsed timer updates every 30 seconds.")
                    tipRow("Sessions are auto-removed when their Claude process exits.")
                    tipRow("Close Session (right-click) removes the pill and closes the terminal tab.")
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 560)
    }

    // MARK: - Section builder

    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            content()
        }
    }

    private func statusRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func interactionRow(action: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(action)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 130, alignment: .trailing)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func shortcutRow(keys: String, desc: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}
