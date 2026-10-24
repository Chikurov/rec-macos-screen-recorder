import AppKit

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, checked: Bool = false, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        self.image = image
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

@MainActor
enum MenuAnchor {
    private static var pendingAnchor: NSRect?
    private static var pendingAt = Date.distantPast
    private static var closedAnchor: NSRect?
    private static var closedAt = Date.distantPast

    static func screenRect(forBarFrame frame: CGRect) -> NSRect? {
        guard frame != .zero, let panel = NSApp.windows.first(where: { $0 is ControlPanel }) else { return nil }
        return NSRect(
            x: panel.frame.minX + frame.minX,
            y: panel.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func prepare(_ anchor: NSRect?, now: Date = Date()) {
        pendingAnchor = anchor
        pendingAt = now
    }

    static func take(now: Date = Date()) -> NSRect? {
        defer { pendingAnchor = nil }
        return now.timeIntervalSince(pendingAt) < 2 ? pendingAnchor : nil
    }

    static func menuOrigin(below anchor: NSRect, menuHeight: CGFloat) -> NSPoint {
        let visible = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? .infinite
        return menuOrigin(below: anchor, menuHeight: menuHeight, visibleFrame: visible)
    }

    nonisolated static func menuOrigin(below anchor: NSRect, menuHeight: CGFloat, visibleFrame visible: NSRect) -> NSPoint {
        let below = NSPoint(x: anchor.minX, y: anchor.minY - 4)
        guard below.y - menuHeight < visible.minY else { return below }
        return NSPoint(x: anchor.minX, y: anchor.maxY + 4 + menuHeight)
    }

    static func justClosed(by anchor: NSRect?, now: Date = Date()) -> Bool {
        guard let anchor, let closedAnchor else { return false }
        return closedAnchor == anchor && now.timeIntervalSince(closedAt) < 0.35
    }

    static func didClose(anchor: NSRect?, now: Date = Date()) {
        closedAnchor = anchor
        closedAt = now
    }
}

extension NSMenu {
    func addSection(_ title: String) {
        if !items.isEmpty {
            addItem(.separator())
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        addItem(header)
    }

    @MainActor
    func popUpAtMouse() {
        let anchor = MenuAnchor.take()
        let location = anchor.map { MenuAnchor.menuOrigin(below: $0, menuHeight: size.height) } ?? NSEvent.mouseLocation
        popUp(positioning: nil, at: location, in: nil)
        MenuAnchor.didClose(anchor: anchor)
    }
}

final class CountdownWindow {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(on screen: NSScreen?, value: Int) {
        if panel == nil {
            let size: CGFloat = 180
            let frame = (screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            let panel = NSPanel(
                contentRect: NSRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let background = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            background.wantsLayer = true
            background.layer?.cornerRadius = 36
            background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            label.font = .monospacedDigitSystemFont(ofSize: 96, weight: .semibold)
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: (size - 116) / 2, width: size, height: 116)
            background.addSubview(label)
            panel.contentView = background
            self.panel = panel
        }
        label.stringValue = "\(value)"
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class AreaBorderWindow {
    var onMove: ((CGVector) -> Void)?
    var onMoveEnded: (() -> Void)?

    private var panel: NSPanel?
    private var handle: NSPanel?
    private var isHandleHidden = false
    private let handleSize = NSSize(width: 118, height: 24)

    func show(around rect: NSRect) {
        let inset: CGFloat = 4
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = makePanel(frame: frame, ignoresMouse: true)
            panel.contentView = DashedBorderView()
            panel.orderFrontRegardless()
            self.panel = panel
        }

        let handleFrame = handleFrame(for: frame)
        if let handle {
            handle.setFrame(handleFrame, display: true)
        } else {
            let handle = makePanel(frame: handleFrame, ignoresMouse: false)
            let view = MoveHandleView()
            view.onDrag = { [weak self] delta in self?.onMove?(delta) }
            view.onDragEnded = { [weak self] in self?.onMoveEnded?() }
            handle.contentView = view
            self.handle = handle
        }
        if !isHandleHidden {
            handle?.orderFrontRegardless()
        }
    }

    func setHandleHidden(_ hidden: Bool) {
        isHandleHidden = hidden
        if hidden {
            handle?.orderOut(nil)
        } else if panel != nil {
            handle?.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        handle?.orderOut(nil)
        panel = nil
        handle = nil
        isHandleHidden = false
    }

    private func handleFrame(for frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.frame ?? frame
        let x = frame.midX - handleSize.width / 2
        let above = NSRect(x: x, y: frame.maxY + 4, width: handleSize.width, height: handleSize.height)
        if above.maxY <= screen.maxY {
            return above
        }
        return NSRect(x: x, y: frame.minY - handleSize.height - 4, width: handleSize.width, height: handleSize.height)
    }

    private func makePanel(frame: NSRect, ignoresMouse: Bool) -> NSPanel {
        let panel = NonActivatingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = ignoresMouse
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class MoveHandleView: NSView {
    var onDrag: ((CGVector) -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastLocation: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        lastLocation = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        if let lastLocation {
            onDrag?(CGVector(dx: location.x - lastLocation.x, dy: location.y - lastLocation.y))
        }
        lastLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
        NSCursor.openHand.set()
        onDragEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.systemRed.withAlphaComponent(0.92).setFill()
        path.fill()
        let text = "⠿  Переместить" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

@MainActor
final class ZoomFrameWindow {
    private var panel: NSPanel?

    func show(around rect: NSRect) {
        let frame = rect.insetBy(dx: -3, dy: -3)
        if let panel {
            panel.setFrame(frame, display: true)
            return
        }
        let panel = NonActivatingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ZoomFrameView()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ZoomFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        NSColor.black.withAlphaComponent(0.28).setStroke()
        path.stroke()
        path.lineWidth = 1.5
        path.setLineDash([7, 5], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}

private final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

@MainActor
final class AreaSelector {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<NSRect?, Never>?

    func select() async -> NSRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            windows = NSScreen.screens.map { screen in
                let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.isOpaque = false
                window.backgroundColor = .clear
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.onFinish = { [weak self] localRect in
                    self?.finish(localRect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) })
                }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                return window
            }
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ rect: NSRect?) {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        continuation?.resume(returning: rect.flatMap { $0.width >= 40 && $0.height >= 40 ? $0.integral : nil })
        continuation = nil
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var startPoint: NSPoint?
    private var selection: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 1.5
            path.stroke()
            let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            text.draw(at: NSPoint(x: selection.minX + 6, y: selection.maxY + 6), withAttributes: attributes)
        } else {
            let hint = "Выделите область мышью · Esc — отмена" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
