import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class ThumbnailModel: ObservableObject {
    @Published var busyMessage: String?
    @Published var isHovering = false
}

@MainActor
final class RecordingThumbnail {
    let actions: RecordingActions

    private var panel: NSPanel?
    private var url: URL?
    private var duration: Double = 0
    private var model = ThumbnailModel()
    private var dismissTask: Task<Void, Never>?
    private var lastAnchor: NSRect?
    private var pendingURL: URL?
    private var pendingBusyMessage: String?
    private var showGeneration = 0
    private let width: CGFloat = 220
    private let stripHeight: CGFloat = 34
    private let gap: CGFloat = 6
    private let visibleDuration: TimeInterval = 6

    init(actions: RecordingActions) {
        self.actions = actions
    }

    var isShowing: Bool { panel != nil }
    var busyMessage: String? { panel == nil ? nil : model.busyMessage }

    func show(url: URL, above anchor: NSRect?) {
        hide(animated: false)
        lastAnchor = anchor
        pendingURL = url
        pendingBusyMessage = nil
        let generation = showGeneration
        Task {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let poster = await Self.poster(for: asset, duration: duration)
            guard generation == showGeneration else { return }
            pendingURL = nil
            present(url: url, poster: poster, duration: duration, anchor: anchor, busyMessage: pendingBusyMessage)
        }
    }

    func setBusy(_ message: String?, for url: URL) {
        if self.url == url, panel != nil {
            model.busyMessage = message
            message == nil ? scheduleDismiss() : dismissTask?.cancel()
        } else if pendingURL == url {
            pendingBusyMessage = message
        } else if let message {
            show(url: url, above: lastAnchor)
            pendingBusyMessage = message
        }
    }

    func hide(animated: Bool = true) {
        showGeneration += 1
        pendingURL = nil
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        url = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -12), display: true)
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func present(url: URL, poster: NSImage?, duration: Double, anchor: NSRect?, busyMessage: String?) {
        panel?.orderOut(nil)
        self.url = url
        self.duration = duration
        model = ThumbnailModel()
        model.busyMessage = busyMessage

        let aspect = poster.map { $0.size.width / max($0.size.height, 1) } ?? 16.0 / 10
        let imageHeight = min(160, max(100, width / aspect))
        let size = NSSize(width: width, height: imageHeight + gap + stripHeight)
        let origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.minX, y: anchor.maxY + 8)
        } else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: visible.minX + 20, y: visible.minY + 20)
        }

        let panel = ThumbnailPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = HoverView(frame: NSRect(origin: .zero, size: size))
        container.onHover = { [weak self] isHovering in
            guard let self else { return }
            model.isHovering = isHovering
            isHovering ? dismissTask?.cancel() : scheduleDismiss()
        }

        let imageView = ThumbnailImageView(url: url, poster: poster, duration: duration)
        imageView.frame = NSRect(x: 0, y: stripHeight + gap, width: width, height: imageHeight)
        imageView.wantsLayer = true
        imageView.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 10
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
        imageView.onOpen = { [weak self] in
            guard let self else { return }
            actions.preview(url)
            hide()
        }
        imageView.onClose = { [weak self] in self?.hide() }
        imageView.onDragCompleted = { [weak self] in self?.hide() }
        imageView.contextMenu = { [weak self] in
            guard let self else { return nil }
            let menu = actions.menu(for: url, duration: duration)
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Закрыть") { [weak self] in self?.hide() })
            return menu
        }
        container.addSubview(imageView)

        let strip = FirstClickHostingView(rootView: ThumbnailActionStrip(
            model: model,
            onTrim: { [weak self] in self?.actions.openInQuickTime(url) },
            onCompress: { [weak self] in
                guard let self else { return }
                let menu = NSMenu()
                for preset in RecordingExports.compressedPresets {
                    menu.addItem(ActionMenuItem(title: actions.compressedTitle(for: preset, duration: duration) + "…") { [weak self] in
                        self?.actions.exportCompressed(url, preset: preset)
                    })
                }
                menu.popUpAtMouse()
            },
            onGIF: { [weak self] in self?.actions.exportGIF(url) },
            onFinder: { [weak self] in self?.actions.revealInFinder(url) }
        ))
        strip.frame = NSRect(x: 0, y: 0, width: width, height: stripHeight)
        container.addSubview(strip)
        panel.contentView = container

        panel.alphaValue = 0
        panel.setFrame(NSRect(origin: origin, size: size).offsetBy(dx: 0, dy: -12), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
        self.panel = panel
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard !model.isHovering, model.busyMessage == nil else { return }
        dismissTask = Task { [weak self, visibleDuration] in
            try? await Task.sleep(for: .seconds(visibleDuration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    static func poster(for asset: AVAsset, duration: Double) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

private struct ThumbnailActionStrip: View {
    @ObservedObject var model: ThumbnailModel
    let onTrim: () -> Void
    let onCompress: () -> Void
    let onGIF: () -> Void
    let onFinder: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let message = model.busyMessage {
                ProgressView().controlSize(.small).tint(.white)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.leading, 4)
            } else {
                StripButton(symbol: "scissors", help: "Обрезать в QuickTime (⌘T)", action: onTrim)
                StripButton(symbol: "paperplane", help: "Сжатая копия для отправки в мессенджеры", action: onCompress)
                StripButton(text: "GIF", help: "GIF-анимация", action: onGIF)
                StripButton(symbol: "folder", help: "Показать в Finder", action: onFinder)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.84)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16)))
        .opacity(model.isHovering || model.busyMessage != nil ? 1 : 0)
        .offset(y: model.isHovering || model.busyMessage != nil ? 0 : -4)
        .animation(.easeOut(duration: 0.18), value: model.isHovering)
        .animation(.easeOut(duration: 0.18), value: model.busyMessage)
    }
}

private struct StripButton: View {
    var symbol: String?
    var text: String?
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    init(symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    init(text: String, help: String, action: @escaping () -> Void) {
        self.text = text
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                } else if let text {
                    Text(text).font(.system(size: 11, weight: .heavy))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isHovering ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class HoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

private final class ThumbnailImageView: NSView, NSDraggingSource {
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onDragCompleted: () -> Void = {}
    var contextMenu: () -> NSMenu? = { nil }

    private let url: URL
    private let poster: NSImage?
    private let duration: Double
    private var mouseDownEvent: NSEvent?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    private var closeRect: NSRect {
        NSRect(x: 6, y: bounds.maxY - 26, width: 20, height: 20)
    }

    init(url: URL, poster: NSImage?, duration: Double) {
        self.url = url
        self.poster = poster
        self.duration = duration
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 4 else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: poster ?? NSImage(size: bounds.size))
        beginDraggingSession(with: [item], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isHovering, closeRect.contains(point) {
            onClose()
        } else {
            onOpen()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] {
            onDragCompleted()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.black.setFill()
        frame.fill()
        poster?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()

        let label = ControlBarView.format(duration) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        let badge = NSRect(x: frame.maxX - size.width - 16, y: frame.minY + 8, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        label.draw(at: NSPoint(x: badge.minX + 5, y: badge.minY + 2), withAttributes: attributes)

        if isHovering {
            let play = NSRect(x: frame.midX - 18, y: frame.midY - 18, width: 36, height: 36)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: play).fill()
            NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Просмотр")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))?
                .tinted(.white)
                .draw(in: play.insetBy(dx: 11, dy: 10))

            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: closeRect).fill()
            NSImage(systemSymbolName: "xmark", accessibilityDescription: "Закрыть")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?
                .tinted(.white)
                .draw(in: closeRect.insetBy(dx: 5.5, dy: 5.5))
        }
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
