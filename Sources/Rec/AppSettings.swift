import AppKit
import Combine

enum BarButton: String, CaseIterable {
    case microphone
    case camera
    case systemAudio
    case countdown
    case zoom
    case folder

    var title: String {
        switch self {
        case .microphone: return "Микрофон"
        case .camera: return "Камера"
        case .systemAudio: return "Системный звук"
        case .countdown: return "Таймер"
        case .zoom: return "Зум"
        case .folder: return "Папка с записями"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .camera: return "video.fill"
        case .systemAudio: return "display"
        case .countdown: return "timer"
        case .zoom: return "plus.magnifyingglass"
        case .folder: return "folder"
        }
    }
}

enum RecordingQuality: String, CaseIterable {
    case high
    case compact

    var title: String {
        switch self {
        case .high: return "Высокое"
        case .compact: return "Компактное"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private var customFolderURL: URL?

    @Published var microphoneEnabled: Bool { didSet { defaults.set(microphoneEnabled, forKey: Keys.microphoneEnabled) } }
    @Published var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: Keys.microphoneID) } }
    @Published var systemAudioEnabled: Bool { didSet { defaults.set(systemAudioEnabled, forKey: Keys.systemAudioEnabled) } }
    @Published var cameraID: String? { didSet { defaults.set(cameraID, forKey: Keys.cameraID) } }
    @Published var cameraSize: Double { didSet { defaults.set(cameraSize, forKey: Keys.cameraSize) } }
    @Published var countdown: Int { didSet { defaults.set(countdown, forKey: Keys.countdown) } }
    @Published var frameRate: Int { didSet { defaults.set(frameRate, forKey: Keys.frameRate) } }
    @Published var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: Keys.showsCursor) } }
    @Published var skin: BarSkin { didSet { defaults.set(skin.rawValue, forKey: Keys.skin) } }
    @Published var quality: RecordingQuality { didSet { defaults.set(quality.rawValue, forKey: Keys.quality) } }
    @Published var slimBar: Bool { didSet { defaults.set(slimBar, forKey: Keys.slimBar) } }
    @Published var hiddenButtons: Set<BarButton> { didSet { defaults.set(hiddenButtons.map(\.rawValue).sorted(), forKey: Keys.hiddenButtons) } }
    @Published private(set) var folderPath: String = ""

    private enum Keys {
        static let microphoneEnabled = "microphoneEnabled"
        static let microphoneID = "microphoneID"
        static let systemAudioEnabled = "systemAudioEnabled"
        static let cameraID = "cameraID"
        static let cameraSize = "cameraSize"
        static let countdown = "countdown"
        static let frameRate = "frameRate"
        static let showsCursor = "showsCursor"
        static let folderBookmark = "folderBookmark"
        static let skin = "skin"
        static let quality = "quality"
        static let lastSource = "lastSource"
        static let hiddenButtons = "hiddenButtons"
        static let slimBar = "slimBar"
    }

    private init() {
        defaults.register(defaults: [
            Keys.microphoneEnabled: false,
            Keys.systemAudioEnabled: true,
            Keys.cameraSize: 200.0,
            Keys.countdown: 3,
            Keys.frameRate: 30,
            Keys.showsCursor: true,
        ])
        microphoneEnabled = defaults.bool(forKey: Keys.microphoneEnabled)
        microphoneID = defaults.string(forKey: Keys.microphoneID)
        systemAudioEnabled = defaults.bool(forKey: Keys.systemAudioEnabled)
        cameraID = defaults.string(forKey: Keys.cameraID)
        cameraSize = defaults.double(forKey: Keys.cameraSize)
        countdown = defaults.integer(forKey: Keys.countdown)
        frameRate = defaults.integer(forKey: Keys.frameRate)
        showsCursor = defaults.bool(forKey: Keys.showsCursor)
        skin = defaults.string(forKey: Keys.skin).flatMap(BarSkin.init(rawValue:)) ?? .system
        quality = defaults.string(forKey: Keys.quality).flatMap(RecordingQuality.init(rawValue:)) ?? .high
        slimBar = defaults.bool(forKey: Keys.slimBar)
        hiddenButtons = Set((defaults.stringArray(forKey: Keys.hiddenButtons) ?? []).compactMap(BarButton.init(rawValue:)))
        restoreCustomFolder()
        folderPath = outputFolder().path
    }

    var lastSource: CaptureSource? {
        get { defaults.data(forKey: Keys.lastSource).flatMap { try? JSONDecoder().decode(CaptureSource.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.lastSource) }
    }

    func outputFolder() -> URL {
        if let customFolderURL {
            return customFolderURL
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent("Rec", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Папка для записей"
        panel.directoryURL = outputFolder()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        customFolderURL?.stopAccessingSecurityScopedResource()
        defaults.set(bookmark, forKey: Keys.folderBookmark)
        restoreCustomFolder()
        folderPath = outputFolder().path
    }

    func resetFolder() {
        customFolderURL?.stopAccessingSecurityScopedResource()
        customFolderURL = nil
        defaults.removeObject(forKey: Keys.folderBookmark)
        folderPath = outputFolder().path
    }

    private func restoreCustomFolder() {
        guard let bookmark = defaults.data(forKey: Keys.folderBookmark) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else {
            defaults.removeObject(forKey: Keys.folderBookmark)
            return
        }
        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: Keys.folderBookmark)
        }
        customFolderURL = url
    }
}
