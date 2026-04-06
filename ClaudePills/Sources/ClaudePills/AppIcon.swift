import AppKit

enum AppIcon {
    /// Generates the ClaudePills app icon programmatically using Claude's color palette.
    static func generate(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let s = size

        // Background: rounded square with Claude's warm gradient
        let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
        let cornerRadius = s * 0.22
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Claude gradient: warm coral → soft peach
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradientColors = [
            CGColor(red: 0.85, green: 0.40, blue: 0.30, alpha: 1.0),  // warm coral
            CGColor(red: 0.95, green: 0.60, blue: 0.40, alpha: 1.0)   // soft peach-orange
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0])!

        ctx.addPath(bgPath)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        ctx.resetClip()

        // Draw 3 pills stacked vertically, slightly offset like a cascade
        let pillWidth = s * 0.52
        let pillHeight = s * 0.13
        let pillRadius = pillHeight / 2
        let centerX = s * 0.5
        let spacing = s * 0.19

        let pillConfigs: [(yCenter: CGFloat, opacity: CGFloat, xOffset: CGFloat)] = [
            (s * 0.32, 0.65, -s * 0.04),    // top pill (slightly left, dimmer)
            (s * 0.32 + spacing, 1.0, 0),     // middle pill (centered, full)
            (s * 0.32 + spacing * 2, 0.80, s * 0.04)  // bottom pill (slightly right)
        ]

        // Pill state dots (blue = running, yellow = waiting, green = complete)
        let dotColors: [CGColor] = [
            CGColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 1.0),   // blue
            CGColor(red: 1.0, green: 0.82, blue: 0.30, alpha: 1.0),   // yellow
            CGColor(red: 0.35, green: 0.90, blue: 0.55, alpha: 1.0)   // green
        ]

        for (i, config) in pillConfigs.enumerated() {
            let pillX = centerX - pillWidth / 2 + config.xOffset
            let pillY = config.yCenter - pillHeight / 2
            let pillRect = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)

            // Pill body: white with opacity
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: config.opacity))
            ctx.addPath(pillPath)
            ctx.fillPath()

            // State dot on the left side of the pill
            let dotRadius = pillHeight * 0.25
            let dotX = pillX + pillHeight * 0.5
            let dotY = config.yCenter
            ctx.setFillColor(dotColors[i])
            ctx.fillEllipse(in: CGRect(
                x: dotX - dotRadius,
                y: dotY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }

        image.unlockFocus()
        return image
    }

    /// Sets the app icon in the dock (for when running as accessory app with temporary dock presence).
    static func setAsAppIcon() {
        NSApp.applicationIconImage = generate()
    }
}
