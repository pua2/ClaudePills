import AppKit
import ApplicationServices

/// Ensures Accessibility permission is granted (needed for AXRaise in focus).
final class AccessibilityManager {
    static let shared = AccessibilityManager()

    func start() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
