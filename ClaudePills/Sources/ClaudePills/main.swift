import AppKit
import Foundation

// Unbuffered stderr for logging
fputs("[ClaudePills] Starting...\n", stderr)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

fputs("[ClaudePills] Running app loop\n", stderr)
app.run()
