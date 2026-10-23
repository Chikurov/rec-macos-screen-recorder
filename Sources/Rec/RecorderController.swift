import AVFoundation
import AppKit
import OSLog
import ScreenCaptureKit

@MainActor
final class RecorderController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case paused
        case saving
    }

    @Published var source: CaptureSource = SourceCatalog.mainDisplaySource()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var cameraEnabled = false

    var openSettings: () -> Void = {}
    var onRecordingSaved: (URL) -> Void = { _ in }

    let settings = AppSettings.shared

    private var engine: RecordingEngine?
    private let cameraBubble = CameraBubble()
    private let countdownWindow = CountdownWindow()
    private let areaBorder = AreaBorderWindow()
    private var areaSelector: AreaSelector?
    private var countdownTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedSeconds: TimeInterval = 0

    var isRecording: Bool {
        phase == .recording || phase == .paused
    }

    init() {
        cameraBubble.onSizeChange = { [weak self] size in
            self?.settings.cameraSize = size
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        switch phase {
        case .idle:
            beginCountdown()
        case .countdown:
            cancelCountdown()
        case .recording, .paused:
            Task { await stopRecording() }
        case .saving:
            break
        }
    }

    func togglePause() {
        guard let engine else { return }
        switch phase {
        case .recording:
            engine.pause()
            pausedAt = Date()
            phase = .paused
        case .paused:
            engine.resume()
            if let pausedAt {
                pausedSeconds += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            phase = .recording
        default:
            break
        }
    }

    func stopRecording() async {
        guard let engine, isRecording else { return }
        phase = .saving
        timer?.invalidate()
        timer = nil
        areaBorder.hide()

        do {
            let url = try await engine.stop()
            if settings.revealAfterRecording {
                onRecordingSaved(url)
            }
        } catch {
            showError(error.localizedDescription)
        }
        self.engine = nil
        elapsed = 0
        phase = .idle
    }

    private func beginCountdown() {
        guard ensureScreenRecordingPermission() else { return }
        countdownTask = Task { [weak self] in
            guard let self else { return }
            if settings.microphoneEnabled, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                showError("Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон или выключите микрофон в Rec.")
                return
            }
            let screen = targetScreen()
            for value in stride(from: settings.countdown, to: 0, by: -1) {
                phase = .countdown(value)
                countdownWindow.show(on: screen, value: value)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    countdownWindow.hide()
                    return
                }
            }
            countdownWindow.hide()
            await startRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownWindow.hide()
        phase = .idle
    }

    private func startRecording() async {
        do {
            let options = try await makeOptions()
            let engine = RecordingEngine()
            engine.onStreamStopped = { [weak self] _ in
                Task { await self?.stopRecording() }
            }
            try await engine.start(options)
            self.engine = engine
            startedAt = Date()
            pausedSeconds = 0
            pausedAt = nil
            phase = .recording
            startTimer()
            if case .area(let rect) = source {
                areaBorder.show(around: rect)
            }
        } catch {
            Logger.rec.error("start failed: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            showError("Не удалось начать запись: \(error.localizedDescription)")
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                let pausedNow = self.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.elapsed = Date().timeIntervalSince(startedAt) - self.pausedSeconds - pausedNow
            }
        }
    }

    private func makeOptions() async throws -> RecordingOptions {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.first { $0.processID == pid }
        let bubble = cameraEnabled ? cameraBubble.windowID.flatMap { id in content.windows.first { $0.windowID == id } } : nil
        let ownWindowsExceptBubble = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowID != bubble?.windowID
        }

        let filter: SCContentFilter
        var sourceRect: CGRect?
        var pointSize: CGSize

        func displayFilter(_ display: SCDisplay) -> SCContentFilter {
            SCContentFilter(display: display, excludingApplications: ownApp.map { [$0] } ?? [], exceptingWindows: bubble.map { [$0] } ?? [])
        }

        switch source {
        case .display(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw CaptureSetupError("Экран не найден.")
            }
            filter = displayFilter(display)
            pointSize = CGSize(width: display.width, height: display.height)

        case .application(let bundleID, let name):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw CaptureSetupError("Приложение «\(name)» не найдено. Возможно, оно закрыто.")
            }
            let appWindows = content.windows.filter { $0.owningApplication?.processID == app.processID && $0.windowLayer == 0 }
            let display = displayContaining(appWindows, in: content)
            var applications = [app]
            if bubble != nil, let ownApp {
                applications.append(ownApp)
            }
            filter = SCContentFilter(display: display, including: applications, exceptingWindows: bubble != nil ? ownWindowsExceptBubble : [])
            pointSize = CGSize(width: display.width, height: display.height)

        case .window(let id, let name):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureSetupError("Окно «\(name)» не найдено. Возможно, оно закрыто.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointSize = window.frame.size

        case .area(let rect):
            guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }),
                  let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw CaptureSetupError("Не удалось определить экран для области.")
            }
            let clipped = rect.intersection(screen.frame)
            filter = displayFilter(display)
            sourceRect = CGRect(
                x: clipped.minX - screen.frame.minX,
                y: screen.frame.maxY - clipped.maxY,
                width: clipped.width,
                height: clipped.height
            )
            pointSize = clipped.size
        }

        let scale = CGFloat(filter.pointPixelScale)
        return RecordingOptions(
            filter: filter,
            sourceRect: sourceRect,
            pixelSize: Self.encodableSize(CGSize(width: pointSize.width * scale, height: pointSize.height * scale)),
            frameRate: settings.frameRate,
            showsCursor: settings.showsCursor,
            systemAudio: settings.systemAudioEnabled,
            microphone: settings.microphoneEnabled ? DeviceCatalog.microphone(id: settings.microphoneID) : nil,
            outputURL: makeOutputURL()
        )
    }

    private func displayContaining(_ windows: [SCWindow], in content: SCShareableContent) -> SCDisplay {
        let largest = windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let largest {
            let center = CGPoint(x: largest.frame.midX, y: largest.frame.midY)
            if let display = content.displays.first(where: { $0.frame.contains(center) }) {
                return display
            }
        }
        return content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays[0]
    }

    private static func encodableSize(_ size: CGSize) -> CGSize {
        let maximum: CGFloat = 3840
        let factor = min(1, maximum / max(size.width, size.height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * factor / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    private func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let name = "Запись \(formatter.string(from: Date())).mp4"
        return settings.outputFolder().appendingPathComponent(name)
    }

    private func targetScreen() -> NSScreen? {
        switch source {
        case .display(let id, _):
            return NSScreen.screens.first { $0.displayID == id }
        case .area(let rect):
            return NSScreen.screens.first { $0.frame.intersects(rect) }
        case .application, .window:
            return NSScreen.main
        }
    }

    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Нужно разрешение «Запись экрана»"
        alert.informativeText = "Включите Rec в Системных настройках → Конфиденциальность и безопасность → Запись экрана, затем завершите и снова откройте Rec."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - Toggles

    func toggleMicrophone() {
        let enable = !settings.microphoneEnabled
        guard isRecording, let engine else {
            settings.microphoneEnabled = enable
            return
        }
        guard enable else {
            try? engine.setMicrophone(nil)
            settings.microphoneEnabled = false
            return
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                showError("Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон.")
                return
            }
            guard let device = DeviceCatalog.microphone(id: settings.microphoneID) else {
                showError("Микрофон не найден.")
                return
            }
            do {
                try engine.setMicrophone(device)
                settings.microphoneEnabled = true
            } catch {
                showError("Не удалось включить микрофон: \(error.localizedDescription)")
            }
        }
    }

    func toggleSystemAudio() {
        settings.systemAudioEnabled.toggle()
        engine?.setSystemAudioMuted(!settings.systemAudioEnabled)
    }

    func toggleCamera() {
        if cameraEnabled {
            cameraBubble.hide()
            cameraEnabled = false
        } else {
            Task { await showCamera() }
        }
    }

    private func showCamera() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            showError("Нет доступа к камере. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Камера.")
            return
        }
        guard let device = DeviceCatalog.camera(id: settings.cameraID) else {
            showError("Камера не найдена.")
            return
        }
        do {
            try cameraBubble.show(device: device, size: settings.cameraSize)
            cameraEnabled = true
        } catch {
            showError("Не удалось включить камеру: \(error.localizedDescription)")
        }
    }

    // MARK: - Menus

    func showSourceMenu() {
        guard !isRecording else { return }
        Task {
            let catalog: SourceCatalog
            do {
                catalog = try await SourceCatalog.load()
            } catch {
                _ = ensureScreenRecordingPermission()
                return
            }

            let menu = NSMenu()
            menu.addSection("Экран")
            for item in catalog.displays {
                menu.addItem(sourceItem(item.source, image: symbol("display")))
            }
            let isArea: Bool
            if case .area = source { isArea = true } else { isArea = false }
            menu.addItem(ActionMenuItem(title: isArea ? source.title : "Область…", checked: isArea, image: symbol("rectangle.dashed")) { [weak self] in
                Task { await self?.selectArea() }
            })

            menu.addItem(.separator())
            menu.addItem(submenuItem(title: "Приложение", symbolName: "app.dashed", items: catalog.applications))
            menu.addItem(submenuItem(title: "Окно", symbolName: "macwindow", items: catalog.windows))
            menu.popUpAtMouse()
        }
    }

    func showMicrophoneMenu() {
        guard !isRecording else { return }
        let menu = NSMenu()
        menu.addSection("Микрофон")
        let current = DeviceCatalog.microphone(id: settings.microphoneID)?.uniqueID
        for device in DeviceCatalog.microphones() {
            menu.addItem(ActionMenuItem(title: device.localizedName, checked: settings.microphoneEnabled && device.uniqueID == current) { [weak self] in
                self?.settings.microphoneID = device.uniqueID
                self?.settings.microphoneEnabled = true
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Без микрофона", checked: !settings.microphoneEnabled) { [weak self] in
            self?.settings.microphoneEnabled = false
        })
        menu.popUpAtMouse()
    }

    func showCameraMenu() {
        let menu = NSMenu()
        menu.addSection("Камера")
        let current = DeviceCatalog.camera(id: settings.cameraID)?.uniqueID
        for device in DeviceCatalog.cameras() {
            menu.addItem(ActionMenuItem(title: device.localizedName, checked: cameraEnabled && device.uniqueID == current) { [weak self] in
                guard let self else { return }
                settings.cameraID = device.uniqueID
                Task { await self.showCamera() }
            })
        }
        menu.addSection("Размер")
        for size in CameraBubble.sizes {
            menu.addItem(ActionMenuItem(title: size.title, checked: settings.cameraSize == size.value) { [weak self] in
                guard let self else { return }
                settings.cameraSize = size.value
                cameraBubble.resize(to: size.value)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Без камеры", checked: !cameraEnabled) { [weak self] in
            guard let self, cameraEnabled else { return }
            toggleCamera()
        })
        menu.popUpAtMouse()
    }

    func showCountdownMenu() {
        let menu = NSMenu()
        menu.addSection("Отсчёт перед записью")
        for (title, value) in [("Без отсчёта", 0), ("3 секунды", 3), ("5 секунд", 5), ("10 секунд", 10)] {
            menu.addItem(ActionMenuItem(title: title, checked: settings.countdown == value) { [weak self] in
                self?.settings.countdown = value
            })
        }
        menu.popUpAtMouse()
    }

    func showMoreMenu() {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title: "Открыть папку с записями", image: symbol("folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(settings.outputFolder())
        })
        menu.addItem(ActionMenuItem(title: "Настройки…", image: symbol("gearshape")) { [weak self] in
            self?.openSettings()
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Выйти из Rec", image: symbol("power")) {
            NSApp.terminate(nil)
        })
        menu.popUpAtMouse()
    }

    private func selectArea() async {
        let selector = AreaSelector()
        areaSelector = selector
        if let rect = await selector.select() {
            source = .area(rect)
        }
        areaSelector = nil
    }

    private func sourceItem(_ itemSource: CaptureSource, image: NSImage?) -> NSMenuItem {
        ActionMenuItem(title: itemSource.title, checked: itemSource == source, image: image) { [weak self] in
            self?.source = itemSource
        }
    }

    private func submenuItem(title: String, symbolName: String, items: [SourceCatalog.Item]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = symbol(symbolName)
        let submenu = NSMenu()
        if items.isEmpty {
            let empty = NSMenuItem(title: "Нет открытых", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for entry in items {
            submenu.addItem(sourceItem(entry.source, image: entry.icon))
        }
        item.submenu = submenu
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Rec"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

struct CaptureSetupError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}
