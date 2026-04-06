import AppKit

final class FloatingPanel: NSPanel {
    /// Which screen edge the panel is docked to.
    var dockSide: DockSide = {
        let raw = UserDefaults.standard.string(forKey: "dockSide") ?? "right"
        return DockSide(rawValue: raw) ?? .right
    }() {
        didSet { onDockSideChanged?(dockSide) }
    }

    /// Called when the dock side changes (for SwiftUI binding).
    var onDockSideChanged: ((DockSide) -> Void)?

    private var dragStartMouseY: CGFloat?
    private var dragStartPanelY: CGFloat?
    private var isDragging = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Event interception for vertical-only drag

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseY = NSEvent.mouseLocation.y
            dragStartPanelY = frame.origin.y
            isDragging = false
            super.sendEvent(event)

        case .leftMouseDragged:
            guard let startMouseY = dragStartMouseY,
                  let startPanelY = dragStartPanelY else {
                super.sendEvent(event)
                return
            }

            let currentY = NSEvent.mouseLocation.y
            if !isDragging && abs(currentY - startMouseY) > 3 {
                isDragging = true
            }

            if isDragging {
                guard let screen = NSScreen.main else { return }
                let screenFrame = screen.frame
                let visible = screen.visibleFrame
                let newY = startPanelY + (currentY - startMouseY)
                let clampedY = max(screenFrame.minY, min(screenFrame.maxY - 10, newY))
                let pinnedX = dockSide == .right
                    ? visible.maxX - frame.width
                    : visible.minX
                setFrameOrigin(NSPoint(x: pinnedX, y: clampedY))
            } else {
                super.sendEvent(event)
            }

        case .leftMouseUp:
            if isDragging {
                UserDefaults.standard.set(frame.origin.y, forKey: "dockPanelY")
            }
            // Always forward mouseUp so SwiftUI buttons clean up press state.
            // Buttons won't fire after a drag because the panel moved underneath.
            super.sendEvent(event)
            dragStartMouseY = nil
            dragStartPanelY = nil
            isDragging = false

        default:
            super.sendEvent(event)
        }
    }

    // MARK: - Side switching (from menu)

    func switchToSide(_ side: DockSide) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let snapX: CGFloat = side == .right
            ? visible.maxX - frame.width
            : visible.minX

        log("switchToSide: \(side.rawValue) snapX=\(snapX) visible=\(visible) frameW=\(frame.width)")

        let target = NSRect(x: snapX, y: frame.origin.y, width: frame.width, height: frame.height)
        setFrame(target, display: true, animate: true)

        dockSide = side
        UserDefaults.standard.set(side.rawValue, forKey: "dockSide")
    }
}
