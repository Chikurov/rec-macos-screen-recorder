import AVFoundation
import AVKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecordingResultWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: ResultModel?

    func show(url: URL) {
        let model = ResultModel(url: url)
        self.model?.player.pause()
        self.model = model

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 380)
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = url.deletingPathExtension().lastPathComponent
        window?.contentView = NSHostingView(rootView: ResultView(model: model))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.player.pause()
        model = nil
    }
}

@MainActor
final class ResultModel: ObservableObject {
    @Published private(set) var url: URL
    @Published private(set) var busyMessage: String?
    @Published private(set) var details = ""
    let player: AVPlayer
    weak var playerView: AVPlayerView?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        Task { await refreshDetails() }
    }

    var isBusy: Bool { busyMessage != nil }

    func trim() {
        guard let playerView, playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            Task { @MainActor in
                guard let self, let item = self.player.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                await self.applyTrim(CMTimeRange(start: start, end: end))
            }
        }
    }

    func exportForTelegram(preset: String, label: String) {
        run("Экспорт для Telegram \(label)…") { [self] in
            let output = sibling(suffix: " (Telegram \(label))", extension: "mp4")
            try await Self.exportPlayableCopy(of: url, to: output, preset: preset)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }

    func exportGIF() {
        run("Создание GIF…") { [self] in
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            if duration > 60 {
                let alert = NSAlert()
                alert.messageText = "Длинный GIF"
                alert.informativeText = "Запись длится \(Int(duration)) с. GIF такой длины получится очень большим. Продолжить?"
                alert.addButton(withTitle: "Продолжить")
                alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let output = sibling(suffix: "", extension: "gif")
            try await Self.makeGIF(from: asset, duration: duration, to: output)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyTrim(_ range: CMTimeRange) async {
        run("Обрезка…") { [self] in
            let asset = AVURLAsset(url: url)
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString)")
                .appendingPathExtension("mp4")
            try await Self.exportTrimmed(asset, range: range, to: temporary)

            player.replaceCurrentItem(with: nil)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            try FileManager.default.moveItem(at: temporary, to: url)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            await refreshDetails()
        }
    }

    private func run(_ message: String, _ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        busyMessage = message
        Task {
            do {
                try await work()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Rec"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            busyMessage = nil
        }
    }

    private func refreshDetails() async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        details = "\(ControlBarView.format(seconds)) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private func sibling(suffix: String, extension pathExtension: String) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(pathExtension)
            index += 1
        }
        return candidate
    }

    static func exportTrimmed(_ asset: AVAsset, range: CMTimeRange, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureSetupError("Не удалось подготовить обрезку.")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? CaptureSetupError("Обрезка не удалась.")
        }
    }

    static func exportPlayableCopy(of url: URL, to output: URL, preset: String) async throws {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureSetupError("В файле нет видео.")
        }
        try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        for track in try await asset.loadTracks(withMediaType: .audio) where try await track.load(.isEnabled) {
            if let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudio.insertTimeRange(range, of: track, at: .zero)
            }
            break
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw CaptureSetupError("Не удалось подготовить экспорт.")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? CaptureSetupError("Экспорт не удался.")
        }
    }

    static func makeGIF(from asset: AVURLAsset, duration: Double, to output: URL) async throws {
        let framesPerSecond = 12.0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let tolerance = CMTime(seconds: 0.5 / framesPerSecond, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = stride(from: 0.0, to: duration, by: 1 / framesPerSecond).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw CaptureSetupError("Не удалось создать GIF.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond]
        ] as CFDictionary

        for await result in generator.images(for: times) {
            if let image = try? result.image {
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw CaptureSetupError("Не удалось сохранить GIF.")
        }
    }
}

private struct ResultView: View {
    @ObservedObject var model: ResultModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(model: model)
            HStack(spacing: 12) {
                Text(model.details)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let message = model.busyMessage {
                    ProgressView().controlSize(.small)
                    Text(message).foregroundStyle(.secondary)
                }
                Button {
                    model.trim()
                } label: {
                    Label("Обрезать", systemImage: "scissors")
                }
                Menu {
                    Button("Для Telegram — 1080p") {
                        model.exportForTelegram(preset: AVAssetExportPreset1920x1080, label: "1080p")
                    }
                    Button("Для Telegram — 720p") {
                        model.exportForTelegram(preset: AVAssetExportPreset1280x720, label: "720p")
                    }
                    Divider()
                    Button("GIF") { model.exportGIF() }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                Button {
                    model.revealInFinder()
                } label: {
                    Label("Показать в Finder", systemImage: "folder")
                }
            }
            .disabled(model.isBusy)
            .padding(12)
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let model: ResultModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsSharingServiceButton = false
        view.player = model.player
        model.playerView = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
