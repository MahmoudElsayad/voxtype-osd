import AppKit
import ApplicationServices

/// Where the panel should appear: the text caret of the focused app, or the mouse pointer when
/// the focused app does not report a caret.
enum Anchor {
    /// The caret rectangle in Cocoa screen coordinates, or the pointer as a zero-size rectangle.
    static func current() -> NSRect {
        caret() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
    }

    private static func caret() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)

        guard let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute),
              let range: AXValue = attribute(focused, kAXSelectedTextRangeAttribute)
        else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds
        ) == .success, let value = bounds, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        return flip(rect)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Accessibility uses a top-left origin on the primary screen; AppKit uses bottom-left.
    private static func flip(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The panel origin: below the anchor, or above it when there is no room, kept on screen.
    static func panelOrigin(for anchor: NSRect, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor.origin) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var y = anchor.minY - Theme.gap - size.height
        if y < visible.minY { y = anchor.maxY + Theme.gap }
        let x = min(max(anchor.minX, visible.minX + Theme.gap), visible.maxX - size.width - Theme.gap)
        return NSPoint(x: x, y: min(y, visible.maxY - size.height - Theme.gap))
    }
}
