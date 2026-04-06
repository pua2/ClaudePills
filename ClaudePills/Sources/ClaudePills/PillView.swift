import SwiftUI
import UniformTypeIdentifiers

struct PillView: View {
    let session: Session
    var dockSide: DockSide = .right
    let onFocus: () -> Void
    let onToggleHide: () -> Void
    let onRename: (String) -> Void
    let onSetColor: (PillColor) -> Void
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var now = Date()

    private var state: SessionState { session.displayState }

    private var stateColor: Color {
        switch state {
        case .running:  Color(red: 0.36, green: 0.58, blue: 1.0)
        case .waiting:  Color(red: 1.0, green: 0.72, blue: 0.16)
        case .question: Color(red: 0.85, green: 0.55, blue: 1.0)
        case .complete: Color(red: 0.29, green: 0.87, blue: 0.49)
        case .hidden:   Color(white: 0.55)
        case .error:    Color(red: 0.97, green: 0.38, blue: 0.38)
        }
    }

    private var accentColor: Color {
        session.pillColor.color ?? stateColor
    }

    private var pillShape: UnevenRoundedRectangle {
        if dockSide.isRight {
            return UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        } else {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 24,
                topTrailingRadius: 24
            )
        }
    }

    private var shadowX: CGFloat {
        dockSide.isRight ? -3 : 3
    }

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            if dockSide.isRight {
                indicatorZone
                if isHovered || isEditing {
                    expandedDetails
                    dragHandle
                }
            } else {
                if isHovered || isEditing {
                    dragHandle
                    expandedDetails
                }
                indicatorZone
            }
        }
        .frame(height: 48)
        .background(
            Color(white: 0.10).opacity(0.95)
                .overlay(accentColor.opacity(session.isHidden ? 0.08 : 0.15))
        )
        .clipShape(pillShape)
        .overlay(pillShape.strokeBorder(accentColor.opacity(0.4), lineWidth: 1.5))
        .shadow(color: accentColor.opacity(0.25), radius: 10, x: shadowX, y: 0)
        .opacity(session.isHidden ? 0.55 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            editText = session.label
            isEditing = true
        }
        .onTapGesture { onFocus() }
        .onReceive(timer) { now = $0 }
        .contextMenu {
            Button("Rename...") {
                editText = session.label
                isEditing = true
            }

            Menu("Color") {
                ForEach(PillColor.allCases, id: \.rawValue) { pillColor in
                    Button {
                        onSetColor(pillColor)
                    } label: {
                        Text("\(pillColor.emoji) \(pillColor.displayName)")
                    }
                }
            }

            Divider()
            Button("Focus Terminal") { onFocus() }
            Button(session.isHidden ? "Show Window" : "Hide Window") { onToggleHide() }
            Divider()
            if let onMoveUp {
                Button("Move Up") { onMoveUp() }
            }
            if let onMoveDown {
                Button("Move Down") { onMoveDown() }
            }
        }
    }

    // MARK: - Drag handle

    private var dragHandle: some View {
        Text("⋮")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white.opacity(0.3))
            .frame(width: 14, height: 48)
            .contentShape(Rectangle())
            .onDrag {
                NSItemProvider(object: session.id as NSString)
            }
    }

    // MARK: - Indicator (always visible)

    private var indicatorZone: some View {
        ZStack {
            switch state {
            case .running:  SpinnerIndicator(color: stateColor)
            case .waiting:  PulsingDot(color: stateColor)
            case .question: Text("?").font(.system(size: 15, weight: .bold)).foregroundColor(stateColor)
            case .complete: Text("✓").font(.system(size: 13, weight: .bold)).foregroundColor(stateColor)
            case .hidden:   Text("−").font(.system(size: 16, weight: .light)).foregroundColor(stateColor.opacity(0.6))
            case .error:    Text("✕").font(.system(size: 12, weight: .bold)).foregroundColor(stateColor)
            }
        }
        .frame(width: 26, height: 48)
    }

    // MARK: - Expanded details

    private var expandedDetails: some View {
        VStack(alignment: dockSide.isRight ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 4) {
                if !dockSide.isRight {
                    actionButton(icon: session.isHidden ? "□" : "−", tooltip: session.isHidden ? "Show" : "Hide", action: onToggleHide)
                    actionButton(icon: "↗", tooltip: "Focus terminal", action: onFocus)
                    Spacer(minLength: 2)
                }

                if isEditing {
                    TextField("Name", text: $editText, onCommit: {
                        onRename(editText)
                        isEditing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: 110)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .onExitCommand { isEditing = false }
                } else {
                    Text(session.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                if dockSide.isRight {
                    Spacer(minLength: 2)
                    actionButton(icon: "↗", tooltip: "Focus terminal", action: onFocus)
                    actionButton(icon: session.isHidden ? "□" : "−", tooltip: session.isHidden ? "Show" : "Hide", action: onToggleHide)
                }
            }

            HStack(spacing: 4) {
                if !dockSide.isRight {
                    Text(session.elapsedString)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }

                Circle().fill(stateColor).frame(width: 5, height: 5)
                if let tool = session.lastTool, state == .running {
                    Text("\(state.label) · \(tool)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Text(state.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }

                if dockSide.isRight {
                    Spacer(minLength: 0)
                    Text(session.elapsedString)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 170)
        .padding(.leading, dockSide.isRight ? 4 : 10)
        .padding(.trailing, dockSide.isRight ? 10 : 4)
        .transition(.opacity.combined(with: .move(edge: dockSide.isRight ? .trailing : .leading)))
    }

    private func actionButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(icon)
                .font(.system(size: icon == "−" || icon == "□" ? 14 : 11, weight: icon == "−" ? .light : .medium))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.75))
        .help(tooltip)
    }
}

// MARK: - Indicator Subviews

struct SpinnerIndicator: View {
    let color: Color
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .scaleEffect(pulsing ? 0.7 : 1.0)
            .opacity(pulsing ? 0.4 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever()) {
                    pulsing = true
                }
            }
    }
}
