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

    func testTelegramCopyHasOnlyTheMixTrack() async throws {
        let recording = try await makeRecording()
        let copy = output("mp4")
        try await RecordingExports.exportCompressedCopy(of: recording, to: copy, preset: RecordingExports.compressedPresets[1])

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
        for preset in RecordingExports.compressedPresets {
            let limit = preset.maxSize
            let copy = output("mp4")
            try await RecordingExports.exportCompressedCopy(of: recording, to: copy, preset: preset)
            let track = try await XCTUnwrapAsync(try await AVURLAsset(url: copy).loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            XCTAssertLessThanOrEqual(size.width, limit.width, preset.label)
            XCTAssertLessThanOrEqual(size.height, limit.height, preset.label)
            XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.02, preset.label)
        }
    }

    func testTelegramCopyDoesNotUpscaleSmallRecordings() async throws {
        let recording = try await makeRecording(size: CGSize(width: 640, height: 360))
        let copy = output("mp4")
        try await RecordingExports.exportCompressedCopy(of: recording, to: copy, preset: RecordingExports.compressedPresets[0])
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: copy).loadTracks(withMediaType: .video).first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))
    }

    func testGIFHasTwelveFramesPerSecond() async throws {
        let recording = try await makeRecording()
        let gif = output("gif")
        let asset = AVURLAsset(url: recording)
        try await RecordingExports.makeGIF(from: asset, duration: try await asset.load(.duration).seconds, to: gif)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 36)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertLessThanOrEqual(properties?[kCGImagePropertyPixelWidth] as? Int ?? .max, 720)
    }

    func testCompressedCopyStaysWithinTheShownEstimate() async throws {
        let recording = try await makeRecording(size: CGSize(width: 2560, height: 1440))
        for preset in RecordingExports.compressedPresets {
            let copy = output("mp4")
            try await RecordingExports.exportCompressedCopy(of: recording, to: copy, preset: preset)
            let bytes = try XCTUnwrap(copy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let estimate = RecordingExports.estimatedCompressedSize(duration: 3, preset: preset)
            XCTAssertLessThanOrEqual(Int64(bytes), estimate + estimate / 10, preset.label)
        }
    }

    func testCompressedEstimateMatchesBitRate() {
        let preset = RecordingExports.compressedPresets[1]
        XCTAssertEqual(RecordingExports.estimatedCompressedSize(duration: 60, preset: preset), Int64(Double(2_500_000 + 128_000) * 60 / 8))
        XCTAssertLessThan(RecordingExports.compressedPresets[1].videoBitRate, RecordingExports.compressedPresets[0].videoBitRate)
    }

    func testFittedSize() {
        XCTAssertEqual(RecordingExports.fittedSize(CGSize(width: 2880, height: 1800), into: CGSize(width: 1280, height: 720)), CGSize(width: 1152, height: 720))
        XCTAssertEqual(RecordingExports.fittedSize(CGSize(width: 640, height: 360), into: CGSize(width: 1280, height: 720)), CGSize(width: 640, height: 360))
        XCTAssertEqual(RecordingExports.fittedSize(CGSize(width: 1080, height: 1920), into: CGSize(width: 1280, height: 720)), CGSize(width: 720, height: 1280))
        XCTAssertEqual(RecordingExports.fittedSize(CGSize(width: 1001, height: 501), into: CGSize(width: 1920, height: 1080)), CGSize(width: 1000, height: 500))
    }

    @MainActor
    func testThumbnailPosterKeepsAspectRatio() async throws {
        let recording = try await makeRecording(size: CGSize(width: 1280, height: 720))
        let asset = AVURLAsset(url: recording)
        let poster = await RecordingThumbnail.poster(for: asset, duration: try await asset.load(.duration).seconds)
        let size = try XCTUnwrap(poster?.size)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.02)
        XCTAssertLessThanOrEqual(size.width, 480)
    }

    func testUniqueURLDoesNotOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let first = RecordingExports.uniqueURL(in: folder, base: "Запись", extension: "gif")
        XCTAssertEqual(first.lastPathComponent, "Запись.gif")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = RecordingExports.uniqueURL(in: folder, base: "Запись", extension: "gif")
        XCTAssertEqual(second.lastPathComponent, "Запись 2.gif")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        XCTAssertEqual(RecordingExports.uniqueURL(in: folder, base: "Запись", extension: "gif").lastPathComponent, "Запись 3.gif")
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
