import AppKit

/// T3 Code Warm Charcoal roles. Values come from the installed theme; do not approximate them.
enum Theme {
    static let surface = NSColor(hex: 0x31302E)
    static let surfaceRaised = NSColor(hex: 0x3A3935)
    static let border = NSColor(hex: 0x45423C)
    static let borderSoft = NSColor(hex: 0x3A3935)
    static let text = NSColor(hex: 0xEDE1BB)
    static let textSecondary = NSColor(hex: 0xCDC1A2)
    static let textMuted = NSColor(hex: 0xAA9E8A)
    static let iconMuted = NSColor(hex: 0x968F7A)
    static let accent = NSColor(hex: 0xEC8743)
    static let accentWashText = NSColor(hex: 0xF3C8A4)
    static let accentSurface = NSColor(hex: 0x4A3A2E)
    static let idleBar = NSColor(hex: 0x59564C)
    static let selection = NSColor(hex: 0x4A4740)
    static let error = NSColor(hex: 0xD0392A)
    static let errorText = NSColor(hex: 0xF5E9D6)
    static let errorSurface = NSColor(hex: 0x3D2A26)

    static let radius: CGFloat = 6
    static let size = NSSize(width: 232, height: 32)
    /// Distance between the caret or pointer and the panel.
    static let gap: CGFloat = 8

    static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let data = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let dataSmall = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let body = NSFont.systemFont(ofSize: 13)
    static let caption = NSFont.systemFont(ofSize: 11)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
