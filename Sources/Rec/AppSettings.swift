import AppKit
import Combine

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
    @Published var revealAfterRecording: Bool { didSet { defaults.set(revealAfterRecording, forKey: Keys.revealAfterRecording) } }
    @Published var skin: BarSkin { didSet { defaults.set(skin.rawValue, forKey: Keys.skin) } }
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
        static let revealAfterRecording = "revealAfterRecording"
        static let folderBookmark = "folderBookmark"
        static let skin = "skin"
    }

    private init() {
        defaults.register(defaults: [
            Keys.microphoneEnabled: false,
            Keys.systemAudioEnabled: true,
            Keys.cameraSize: 200.0,
            Keys.countdown: 3,
            Keys.frameRate: 30,
            Keys.showsCursor: true,
            Keys.revealAfterRecording: true
        ])
        microphoneEnabled = defaults.bool(forKey: Keys.microphoneEnabled)
        microphoneID = defaults.string(forKey: Keys.microphoneID)
        systemAudioEnabled = defaults.bool(forKey: Keys.systemAudioEnabled)
        cameraID = defaults.string(forKey: Keys.cameraID)
        cameraSize = defaults.double(forKey: Keys.cameraSize)
        countdown = defaults.integer(forKey: Keys.countdown)
        frameRate = defaults.integer(forKey: Keys.frameRate)
        showsCursor = defaults.bool(forKey: Keys.showsCursor)
        revealAfterRecording = defaults.bool(forKey: Keys.revealAfterRecording)
        skin = defaults.string(forKey: Keys.skin).flatMap(BarSkin.init(rawValue:)) ?? .dark
        restoreCustomFolder()
        folderPath = outputFolder().path
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
