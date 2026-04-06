import SwiftUI
import UniformTypeIdentifiers

enum DockSide: String {
    case left, right

    var isRight: Bool { self == .right }
}

struct DockView: View {
    @EnvironmentObject var manager: SessionManager
    @State private var dockSide: DockSide = {
        let raw = UserDefaults.standard.string(forKey: "dockSide") ?? "right"
        return DockSide(rawValue: raw) ?? .right
    }()

    var body: some View {
        let alignment: Alignment = dockSide.isRight ? .trailing : .leading

        VStack(alignment: dockSide.isRight ? .trailing : .leading, spacing: 6) {
            ForEach(manager.visibleSessions) { session in
                pillView(for: session)
            }

            addButton
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .onAppear {
            if let panel = NSApp.windows.compactMap({ $0 as? FloatingPanel }).first {
                panel.onDockSideChanged = { newSide in
                    withAnimation(.easeOut(duration: 0.25)) {
                        dockSide = newSide
                    }
                }
            }
        }
    }

    private func pillView(for session: Session) -> some View {
        let visible = manager.visibleSessions
        let isFirst = visible.first?.id == session.id
        let isLast = visible.last?.id == session.id

        return PillView(
            session: session,
            dockSide: dockSide,
            onFocus: {
                if session.isHidden {
                    manager.toggleHidden(id: session.id)
                }
                TerminalBridge.focusSession(terminalSessionId: session.terminalSessionId)
            },
            onToggleHide: {
                if session.isHidden {
                    TerminalBridge.showSession(terminalSessionId: session.terminalSessionId)
                } else {
                    TerminalBridge.hideSession(terminalSessionId: session.terminalSessionId)
                }
                manager.toggleHidden(id: session.id)
            },
            onRename: { newName in
                manager.rename(id: session.id, to: newName)
            },
            onSetColor: { color in
                manager.setColor(id: session.id, color: color)
            },
            onMoveUp: isFirst ? nil : { manager.moveSessionUp(id: session.id) },
            onMoveDown: isLast ? nil : { manager.moveSessionDown(id: session.id) }
        )
        .onDrop(of: [.plainText], delegate: PillDropDelegate(
            targetId: session.id,
            manager: manager
        ))
    }

    private var addButton: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: dockSide.isRight ? 13 : 0,
            bottomLeadingRadius: dockSide.isRight ? 13 : 0,
            bottomTrailingRadius: dockSide.isRight ? 0 : 13,
            topTrailingRadius: dockSide.isRight ? 0 : 13
        )

        return Button(action: { TerminalBridge.createNewWindow() }) {
            Text("+")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(Color(white: 0.10).opacity(0.95))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct PillDropDelegate: DropDelegate {
    let targetId: String
    let manager: SessionManager

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
            guard let data = data as? Data, let draggedId = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                manager.moveSession(id: draggedId, toId: targetId)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            if hovering { cursor.push() }
            else { NSCursor.pop() }
        }
    }
}
