import AVFoundation
import AppKit
import ScreenCaptureKit

enum CaptureSource: Equatable, Codable {
    case display(CGDirectDisplayID, name: String)
    case application(bundleID: String, name: String)
    case window(CGWindowID, name: String)
    case area(NSRect)

    var title: String {
        switch self {
        case .display(_, let name), .application(_, let name), .window(_, let name):
            return name
        case .area(let rect):
            return "Область \(Int(rect.width))×\(Int(rect.height))"
        }
    }

    static func restored(_ saved: CaptureSource?, displays: [CGDirectDisplayID: String], screenFrames: [NSRect]) -> CaptureSource? {
        switch saved {
        case .display(let id, _):
            return displays[id].map { .display(id, name: $0) }
        case .application:
            return saved
        case .area(let rect):
            return screenFrames.contains(where: { $0.contains(rect) }) ? saved : nil
        case .window, .none:
            return nil
        }
    }

    var symbol: String {
        switch self {
        case .display: return "display"
        case .application: return "app.dashed"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }
}

struct SourceCatalog {
    struct Item {
        let source: CaptureSource
        let icon: NSImage?
    }

    let displays: [Item]
    let applications: [Item]
    let windows: [Item]

    static func load() async throws -> SourceCatalog {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let displays = content.displays.map { display in
            Item(source: .display(display.displayID, name: displayName(for: display.displayID)), icon: nil)
        }

        let visibleWindows = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != ownPID else { return false }
            return window.windowLayer == 0 && window.frame.width >= 100 && window.frame.height >= 60
        }

        var seenBundleIDs = Set<String>()
        let applications = visibleWindows
            .compactMap(\.owningApplication)
            .filter { !$0.bundleIdentifier.isEmpty && seenBundleIDs.insert($0.bundleIdentifier).inserted }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
            .map { app in
                Item(source: .application(bundleID: app.bundleIdentifier, name: app.applicationName), icon: appIcon(pid: app.processID))
            }

        let windows = visibleWindows
            .filter { !($0.title ?? "").isEmpty }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            .map { window in
                let appName = window.owningApplication?.applicationName ?? ""
                let title = String((window.title ?? "").prefix(60))
                return Item(
                    source: .window(window.windowID, name: "\(appName) — \(title)"),
                    icon: window.owningApplication.flatMap { appIcon(pid: $0.processID) }
                )
            }

        return SourceCatalog(displays: displays, applications: applications, windows: windows)
    }

    static func mainDisplaySource() -> CaptureSource {
        let id = CGMainDisplayID()
        return .display(id, name: displayName(for: id))
    }

    static func displayName(for id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "Экран"
    }

    private static func appIcon(pid: pid_t) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

enum DeviceCatalog {
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    static func microphone(id: String?) -> AVCaptureDevice? {
        if let id, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    static func camera(id: String?) -> AVCaptureDevice? {
        if let id, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .video) ?? cameras().first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
