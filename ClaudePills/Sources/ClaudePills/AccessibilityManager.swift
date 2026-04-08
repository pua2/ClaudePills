import AppKit
import ApplicationServices

/// Ensures Accessibility permission is granted (needed for AXRaise in focus).
final class AccessibilityManager {
    static let shared = AccessibilityManager()

    private let promptedKey = "accessibilityPromptShown"

    func start() {
        guard !AXIsProcessTrusted() else { return }

        // Only show the system prompt once. After that, the user knows where to
        // grant it (System Settings > Privacy & Security > Accessibility) and
        // re-prompting every launch is disruptive — especially with ad-hoc signing
        // where the CDHash changes on every update.
        if !UserDefaults.standard.bool(forKey: promptedKey) {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            UserDefaults.standard.set(true, forKey: promptedKey)
        }
    }
}
