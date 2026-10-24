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

    @Published var source: CaptureSource = SourceCatalog.mainDisplaySource() {
        didSet { settings.lastSource = source }
    }
    @Published private(set) var phase: Phase = .idle
    #if DEBUG
    func setPhaseForTesting(_ phase: Phase) { self.phase = phase }
    #endif
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var cameraEnabled = false
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var isZoomed = false

    private struct CaptureGeometry {
        let screenFrame: NSRect
        var baseRect: CGRect
    }

    private var geometry: CaptureGeometry?
    private var currentSourceRect: CGRect?
    private var zoomTimer: Timer?
    private var movingArea: NSRect?

    var canZoom: Bool {
        isRecording && geometry != nil
    }

    var onRecordingSaved: (URL) -> Void = { _ in }
    var recordingMenu: (URL, Double) -> NSMenu? = { _, _ in nil }
    private var lastRecording: (url: URL, duration: Double)?

    let settings = AppSettings.shared

    private var engine: RecordingEngine?
    private let cameraBubble = CameraBubble()
    private let countdownWindow = CountdownWindow()
    private let areaBorder = AreaBorderWindow()
    private let zoomFrame = ZoomFrameWindow()
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
        let displays = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.displayID, $0.localizedName) })
        if let restored = CaptureSource.restored(settings.lastSource, displays: displays, screenFrames: NSScreen.screens.map(\.frame)) {
            source = restored
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
        finishMovingArea()
        timer?.invalidate()
        timer = nil
        zoomTimer?.invalidate()
        zoomTimer = nil
        isZoomed = false
        geometry = nil
        currentSourceRect = nil
        areaBorder.hide()
        zoomFrame.hide()

        do {
            let url = try await engine.stop()
            lastRecording = (url, elapsed)
            onRecordingSaved(url)
        } catch {
            showError(error.localizedDescription)
        }
        self.engine = nil
        elapsed = 0
        microphoneLevel = 0
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
            let (options, geometry) = try await makeOptions()
            let engine = RecordingEngine()
            engine.onStreamStopped = { [weak self] _ in
                Task { await self?.stopRecording() }
            }
            engine.onMicrophoneLevel = { [weak self] level in
                guard let self, settings.microphoneEnabled else { return }
                microphoneLevel = level
            }
            try await engine.start(options)
            self.engine = engine
            self.geometry = geometry
            currentSourceRect = geometry?.baseRect
            isZoomed = false
            startedAt = Date()
            pausedSeconds = 0
            pausedAt = nil
            phase = .recording
            startTimer()
            if case .area(let rect) = source {
                areaBorder.onMove = { [weak self] delta in self?.moveArea(by: delta) }
                areaBorder.onMoveEnded = { [weak self] in self?.finishMovingArea() }
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

    private func makeOptions() async throws -> (RecordingOptions, CaptureGeometry?) {
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
        var geometry: CaptureGeometry?

        func displayGeometry(_ display: SCDisplay) -> CaptureGeometry? {
            NSScreen.screens.first { $0.displayID == display.displayID }.map {
                CaptureGeometry(screenFrame: $0.frame, baseRect: CGRect(origin: .zero, size: $0.frame.size))
            }
        }

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
            geometry = displayGeometry(display)

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
            geometry = displayGeometry(display)

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
            let area = Self.captureArea(for: rect, in: screen.frame)
            filter = displayFilter(display)
            sourceRect = area
            pointSize = area.size
            geometry = CaptureGeometry(screenFrame: screen.frame, baseRect: area)
        }

        let scale = Self.captureScale(pointPixelScale: filter.pointPixelScale, quality: settings.quality)
        let options = RecordingOptions(
            filter: filter,
            sourceRect: sourceRect,
            pixelSize: Self.encodableSize(CGSize(width: pointSize.width * scale, height: pointSize.height * scale)),
            frameRate: settings.frameRate,
            showsCursor: settings.showsCursor,
            systemAudio: settings.systemAudioEnabled,
            microphone: settings.microphoneEnabled ? DeviceCatalog.microphone(id: settings.microphoneID) : nil,
            outputURL: makeOutputURL()
        )
        return (options, geometry)
    }

    // MARK: - Zoom and area movement

    func toggleZoom() {
        guard canZoom, let geometry else {
            let menu = NSMenu()
            let hint = NSMenuItem(title: "Зум работает во время записи экрана или области:", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            let detail = NSMenuItem(title: "нажмите 🔍 и выделите фрагмент, который нужно приблизить", action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.popUpAtMouse()
            return
        }
        if isZoomed {
            isZoomed = false
            zoomFrame.hide()
            animateSourceRect(to: geometry.baseRect)
            return
        }
        Task {
            guard let selection = await AreaSelector().select(), isRecording, let geometry = self.geometry else { return }
            let local = Self.captureArea(for: selection, in: geometry.screenFrame)
            guard local.width >= 20, local.height >= 20 else { return }
            isZoomed = true
            areaBorder.setHandleHidden(true)
            animateSourceRect(to: Self.zoomRect(for: local, matching: geometry.baseRect))
        }
    }

    private func animateSourceRect(to target: CGRect) {
        guard let engine else { return }
        zoomTimer?.invalidate()
        let start = currentSourceRect ?? target
        let startedAt = Date()
        let duration: TimeInterval = 0.5
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let progress = min(1, Date().timeIntervalSince(startedAt) / duration)
                let rect = Self.interpolate(from: start, to: target, progress: Self.easeOut(progress))
                self.currentSourceRect = rect
                engine.updateSourceRect(rect)
                if self.isZoomed, let geometry = self.geometry {
                    self.zoomFrame.show(around: Self.screenRect(forCaptureArea: rect, in: geometry.screenFrame))
                }
                if progress >= 1 {
                    timer.invalidate()
                    self.zoomTimer = nil
                    if !self.isZoomed {
                        self.areaBorder.setHandleHidden(false)
                    }
                }
            }
        }
    }

    private func moveArea(by delta: CGVector) {
        guard case .area(let rect) = source, isRecording, !isZoomed, var geometry, let engine else { return }
        let current = movingArea ?? rect
        let moved = Self.clampedArea(current.offsetBy(dx: delta.dx, dy: delta.dy), in: geometry.screenFrame)
        guard moved != current else { return }
        movingArea = moved
        geometry.baseRect = Self.captureArea(for: moved, in: geometry.screenFrame)
        self.geometry = geometry
        currentSourceRect = geometry.baseRect
        areaBorder.show(around: moved)
        engine.updateSourceRect(geometry.baseRect)
    }

    private func finishMovingArea() {
        if let movingArea {
            source = .area(movingArea)
        }
        movingArea = nil
    }

    nonisolated static func clampedArea(_ rect: NSRect, in screenFrame: NSRect) -> NSRect {
        var result = rect
        result.origin.x = min(max(result.minX, screenFrame.minX), screenFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, screenFrame.minY), screenFrame.maxY - result.height)
        return result
    }

    nonisolated static func zoomRect(for selection: CGRect, matching base: CGRect, maximumZoom: CGFloat = 4) -> CGRect {
        let aspect = base.width / base.height
        var size = selection.size
        if size.width / size.height > aspect {
            size.height = size.width / aspect
        } else {
            size.width = size.height * aspect
        }
        let minimumWidth = base.width / maximumZoom
        if size.width < minimumWidth {
            size = CGSize(width: minimumWidth, height: minimumWidth / aspect)
        }
        if size.width > base.width {
            size = base.size
        }
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.midY - size.height / 2)
        origin.x = min(max(origin.x, base.minX), base.maxX - size.width)
        origin.y = min(max(origin.y, base.minY), base.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    nonisolated static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - min(max(t, 0), 1), 4)
    }

    nonisolated static func interpolate(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let p = CGFloat(progress)
        return CGRect(
            x: start.minX + (end.minX - start.minX) * p,
            y: start.minY + (end.minY - start.minY) * p,
            width: start.width + (end.width - start.width) * p,
            height: start.height + (end.height - start.height) * p
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

    nonisolated static func captureArea(for rect: NSRect, in screenFrame: NSRect) -> CGRect {
        let clipped = rect.intersection(screenFrame)
        return CGRect(
            x: clipped.minX - screenFrame.minX,
            y: screenFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    nonisolated static func screenRect(forCaptureArea area: CGRect, in screenFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.minX + area.minX,
            y: screenFrame.maxY - area.maxY,
            width: area.width,
            height: area.height
        )
    }

    struct QualityEstimate: Equatable {
        let size: CGSize
        let aspect: String
        let megabytesPerMinute: Int
    }

    nonisolated static func qualityEstimate(pointSize: CGSize, scale: CGFloat, frameRate: Int) -> QualityEstimate {
        let size = encodableSize(CGSize(width: pointSize.width * scale, height: pointSize.height * scale))
        let videoBits = RecordingEngine.videoBitRate(width: Int(size.width), height: Int(size.height), frameRate: frameRate)
        let audioBits = 160_000 * 2 + 96_000
        let megabytes = Double(videoBits + audioBits) * 60 / 8 / 1_000_000
        return QualityEstimate(size: size, aspect: aspectRatio(pointSize), megabytesPerMinute: Int((megabytes / 5).rounded() * 5))
    }

    nonisolated static func aspectRatio(_ size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "—" }
        let ratio = size.width / size.height
        let known: [(String, CGFloat)] = [("16:9", 16.0 / 9), ("16:10", 16.0 / 10), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("21:9", 64.0 / 27), ("1:1", 1)]
        if let match = known.first(where: { abs($0.1 - ratio) < 0.02 }) {
            return match.0
        }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let divisor = max(1, gcd(width, height))
        return "\(width / divisor):\(height / divisor)"
    }

    nonisolated static func captureScale(pointPixelScale: Float, quality: RecordingQuality) -> CGFloat {
        switch quality {
        case .high: return CGFloat(max(1, pointPixelScale))
        case .compact: return 1
        }
    }

    nonisolated static func encodableSize(_ size: CGSize) -> CGSize {
        let maximum: CGFloat = 3840
        let factor = min(1, maximum / max(size.width, size.height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * factor / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    private func makeOutputURL() -> URL {
        settings.outputFolder().appendingPathComponent(Self.outputFileName(for: Date()))
    }

    nonisolated static func outputFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return "Запись \(formatter.string(from: date)).mp4"
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
            microphoneLevel = 0
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

    func lastRecordingMenuItem() -> NSMenuItem? {
        guard let lastRecording, FileManager.default.fileExists(atPath: lastRecording.url.path),
              let submenu = recordingMenu(lastRecording.url, lastRecording.duration) else { return nil }
        let item = NSMenuItem(title: "Последняя запись", action: nil, keyEquivalent: "")
        item.image = symbol("film")
        item.submenu = submenu
        return item
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(settings.outputFolder())
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
