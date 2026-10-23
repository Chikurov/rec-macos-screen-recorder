import AVFoundation
import ImageIO
import XCTest
@testable import Rec

final class ExportTests: XCTestCase {
    private func makeRecording(size: CGSize = CGSize(width: 640, height: 360)) async throws -> URL {
        let source = TestMedia.temporaryURL("mov")
        let recording = TestMedia.temporaryURL("mp4")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: recording)
        }
        try await TestMedia.writeMovie(to: source, size: size, audio: [
            .init(channels: 2, planar: true, frequency: 440, spans: [0...3]),
            .init(channels: 1, planar: false, frequency: 660, spans: [0...3])
        ])
        try await AudioMixer.mix(source: source, destination: recording)
        return recording
    }

    private func output(_ pathExtension: String) -> URL {
        let url = TestMedia.temporaryURL(pathExtension)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTrimKeepsAllTracksAndTheirFlags() async throws {
        let recording = try await makeRecording()
        let trimmed = output("mp4")
        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), end: CMTime(seconds: 2.5, preferredTimescale: 600))
        try await ResultModel.exportTrimmed(AVURLAsset(url: recording), range: range, to: trimmed)

        let asset = AVURLAsset(url: trimmed)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 3)
        guard audio.count == 3 else { return }
        var enabled: [Bool] = []
        for track in audio { enabled.append(try await track.load(.isEnabled)) }
        XCTAssertEqual(enabled, [true, false, false])
    }

    func testTelegramCopyHasOnlyTheMixTrack() async throws {
        let recording = try await makeRecording()
        let copy = output("mp4")
        try await ResultModel.exportPlayableCopy(of: recording, to: copy, preset: AVAssetExportPreset1280x720)

        let asset = AVURLAsset(url: copy)
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(audioTrackCount, 1)
        let videoTrackCount = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(videoTrackCount, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.1)
    }

    func testTelegramCopyDownscalesLargeRecordings() async throws {
        let recording = try await makeRecording(size: CGSize(width: 2560, height: 1440))
        for (preset, limit) in [(AVAssetExportPreset1280x720, CGSize(width: 1280, height: 720)), (AVAssetExportPreset1920x1080, CGSize(width: 1920, height: 1080))] {
            let copy = output("mp4")
            try await ResultModel.exportPlayableCopy(of: recording, to: copy, preset: preset)
            let track = try await XCTUnwrapAsync(try await AVURLAsset(url: copy).loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            XCTAssertLessThanOrEqual(size.width, limit.width, preset)
            XCTAssertLessThanOrEqual(size.height, limit.height, preset)
            XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.02, preset)
        }
    }

    func testTelegramCopyDoesNotUpscaleSmallRecordings() async throws {
        let recording = try await makeRecording(size: CGSize(width: 640, height: 360))
        let copy = output("mp4")
        try await ResultModel.exportPlayableCopy(of: recording, to: copy, preset: AVAssetExportPreset1920x1080)
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: copy).loadTracks(withMediaType: .video).first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))
    }

    func testGIFHasTwelveFramesPerSecond() async throws {
        let recording = try await makeRecording()
        let gif = output("gif")
        let asset = AVURLAsset(url: recording)
        try await ResultModel.makeGIF(from: asset, duration: try await asset.load(.duration).seconds, to: gif)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 36)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertLessThanOrEqual(properties?[kCGImagePropertyPixelWidth] as? Int ?? .max, 720)
    }

    func testUniqueURLDoesNotOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let first = ResultModel.uniqueURL(in: folder, base: "Запись", extension: "gif")
        XCTAssertEqual(first.lastPathComponent, "Запись.gif")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = ResultModel.uniqueURL(in: folder, base: "Запись", extension: "gif")
        XCTAssertEqual(second.lastPathComponent, "Запись 2.gif")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        XCTAssertEqual(ResultModel.uniqueURL(in: folder, base: "Запись", extension: "gif").lastPathComponent, "Запись 3.gif")
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
