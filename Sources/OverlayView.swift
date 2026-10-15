import AppKit

enum Phase: Equatable {
    case recording
    case transcribing
    case rewriting
    case cancelled
}

/// One flat Warm Charcoal strip: a state dot and label, a level meter, and the elapsed time.
final class OverlayView: NSView {
    var phase: Phase = .recording { didSet { needsDisplay = true } }
    var elapsed: TimeInterval = 0 { didSet { needsDisplay = true } }
    /// Recording continues without holding a key; the next right Command press stops it.
    /// The strip can then be dragged out of the way; otherwise clicks pass through it.
    var handsFree = false {
        didSet {
            needsDisplay = true
            window?.ignoresMouseEvents = !handsFree
            if !handsFree { NSCursor.arrow.set() }
        }
    }

    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let framesPerBar = 4
    /// Room noise on a MacBook microphone sits near -47 dBFS; close speech peaks near -15.
    private static let floorDbfs: Float = -50
    private static let ceilingDbfs: Float = -15

    private var bars: [CGFloat] = []
    private var pendingPeak: Float = -.infinity
    private var pendingFrames = 0

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    // The panel never activates the app, so the first click must already start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { if handsFree { NSCursor.openHand.set() } }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        guard handsFree else { return }
        NSCursor.closedHand.set()
        window?.performDrag(with: event)
        NSCursor.openHand.set()
    }

    func reset() {
        bars.removeAll()
        pendingPeak = -.infinity
        pendingFrames = 0
        elapsed = 0
    }

    /// Feeds one 10 ms level frame. Every few frames become one bar.
    func push(peakDbfs: Float) {
        pendingPeak = max(pendingPeak, peakDbfs)
        pendingFrames += 1
        guard pendingFrames == Self.framesPerBar else { return }
        let level = (pendingPeak - Self.floorDbfs) / (Self.ceilingDbfs - Self.floorDbfs)
        bars.append(CGFloat(min(max(level, 0), 1)))
        if bars.count > 128 { bars.removeFirst(bars.count - 128) }
        pendingPeak = -.infinity
        pendingFrames = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: frame, xRadius: Theme.radius, yRadius: Theme.radius)
        (phase == .cancelled ? Theme.errorSurface : Theme.surface).setFill()
        shape.fill()
        (phase == .cancelled ? Theme.error : Theme.border).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let midY = bounds.midY
        var x: CGFloat = 12

        let dot = NSRect(x: x, y: midY - 3, width: 6, height: 6)
        drawMark(in: dot)
        x = dot.maxX + 8

        let label = NSAttributedString(string: labelText, attributes: [
            .font: Theme.label,
            .kern: 0.88,
            .foregroundColor: labelColor,
        ])
        let labelSize = label.size()
        label.draw(at: NSPoint(x: x, y: midY - labelSize.height / 2))
        x += labelSize.width + 12

        let time = NSAttributedString(string: Self.format(elapsed), attributes: [
            .font: Theme.data,
            .foregroundColor: phase == .cancelled ? Theme.errorText : Theme.textMuted,
        ])
        let timeSize = time.size()
        let timeX = bounds.maxX - 12 - timeSize.width
        time.draw(at: NSPoint(x: timeX, y: midY - timeSize.height / 2))

        drawMeter(in: NSRect(x: x, y: 8, width: timeX - 12 - x, height: bounds.height - 16))
    }

    private var labelText: String {
        switch phase {
        case .recording: handsFree ? "HANDS-FREE" : "REC"
        case .transcribing: "TRANSCRIBING"
        case .rewriting: "REWRITING"
        case .cancelled: "CANCELLED"
        }
    }

    private var labelColor: NSColor {
        switch phase {
        case .recording: Theme.text
        case .transcribing, .rewriting: Theme.textMuted
        case .cancelled: Theme.errorText
        }
    }

    /// A solid orange dot while recording, an orange ring while transcribing or rewriting, a red cross when cancelled.
    private func drawMark(in rect: NSRect) {
        switch phase {
        case .recording:
            Theme.accent.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .transcribing, .rewriting:
            Theme.accent.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        case .cancelled:
            Theme.error.setStroke()
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: rect.minX, y: rect.minY))
            cross.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            cross.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            cross.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            cross.lineWidth = 1.5
            cross.lineCapStyle = .round
            cross.stroke()
        }
    }

    /// Newest bar on the right. After recording the meter freezes and dims.
    private func drawMeter(in rect: NSRect) {
        guard rect.width > 0 else { return }
        let step = Self.barWidth + Self.barGap
        let slots = Int((rect.width + Self.barGap) / step)
        let shown = bars.suffix(slots)
        (phase == .recording ? Theme.text : Theme.idleBar).setFill()

        for slot in 0..<slots {
            let index = shown.count - slots + slot
            let level = index >= 0 ? shown[shown.startIndex + index] : 0
            let height = max(2, (rect.height * level).rounded())
            let x = rect.minX + CGFloat(slot) * step
            NSRect(x: x, y: rect.midY - height / 2, width: Self.barWidth, height: height).fill()
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
