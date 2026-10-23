import AVFoundation
import AppKit

final class CameraBubble: NSObject {
    static let sizes: [(title: String, value: Double)] = [("Маленькая", 140), ("Средняя", 200), ("Большая", 280), ("Очень большая", 380)]

    var onSizeChange: ((Double) -> Void)?

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.chikurov.Rec.camera")

    var windowID: CGWindowID? {
        panel.map { CGWindowID($0.windowNumber) }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(device: AVCaptureDevice, size: Double) throws {
        stopSession()

        let session = AVCaptureSession()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let panel = self.panel ?? makePanel(size: size)
        (panel.contentView as? BubbleView)?.attach(session)
        panel.orderFrontRegardless()

        self.panel = panel
        self.session = session
        sessionQueue.async { session.startRunning() }
    }

    func hide() {
        panel?.orderOut(nil)
        stopSession()
    }

    private func stopSession() {
        if let session {
            sessionQueue.async { session.stopRunning() }
        }
        session = nil
    }

    private func makePanel(size: Double) -> NSPanel {
        let view = BubbleView()
        view.onSizeSelected = { [weak self] size in
            self?.resize(to: size)
            self?.onSizeChange?(size)
        }

        let panel = BubblePanel(
            contentRect: initialFrame(size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        return panel
    }

    func resize(to size: Double) {
        guard let panel else { return }
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true, animate: true)
    }

    private func initialFrame(size: Double) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - size - 40, y: visible.minY + 40, width: size, height: size)
    }
}

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class BubbleView: NSView {
    var onSizeSelected: ((Double) -> Void)?
    private let previewLayer = AVCaptureVideoPreviewLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    func attach(_ session: AVCaptureSession) {
        previewLayer.session = session
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for size in CameraBubble.sizes {
            menu.addItem(ActionMenuItem(title: size.title) { [weak self] in
                self?.onSizeSelected?(size.value)
            })
        }
        return menu
    }
}
