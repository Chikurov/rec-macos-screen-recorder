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

extension NSMenu {
    func addSection(_ title: String) {
        if !items.isEmpty {
            addItem(.separator())
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        addItem(header)
    }

    func popUpAtMouse() {
        popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
    private var panel: NSPanel?

    func show(around rect: NSRect) {
        hide()
        let inset: CGFloat = 4
        let panel = NSPanel(
            contentRect: rect.insetBy(dx: -inset, dy: -inset),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = DashedBorderView()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
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
