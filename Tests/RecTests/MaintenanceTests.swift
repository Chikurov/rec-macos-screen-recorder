import AVFoundation
import XCTest
@testable import Rec

final class MicrophoneLevelTests: XCTestCase {
    func testNormalizedLevelScale() {
        XCTAssertEqual(RecordingEngine.normalizedLevel(peak: 0), 0)
        XCTAssertEqual(RecordingEngine.normalizedLevel(peak: 1), 1)
        XCTAssertEqual(RecordingEngine.normalizedLevel(peak: 2), 1)
        XCTAssertEqual(RecordingEngine.normalizedLevel(peak: 0.0001), 0)
        XCTAssertEqual(RecordingEngine.normalizedLevel(peak: 0.1), 0.6, accuracy: 0.001)
    }

    func testPeakOfBuffer() throws {
        let buffer = try XCTUnwrap(TestMedia.sine(.init(channels: 1, planar: false, frequency: 440, spans: [0...1])).first)
        XCTAssertEqual(RecordingEngine.peak(of: buffer), 0.3, accuracy: 0.01)
    }
}

final class SourceMemoryTests: XCTestCase {
    private let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]

    func testCodableRoundTrip() throws {
        for source in [
            CaptureSource.display(7, name: "Экран"),
            .application(bundleID: "com.google.Chrome", name: "Chrome"),
            .window(42, name: "Chrome — Почта"),
            .area(NSRect(x: 10, y: 20, width: 300, height: 200))
        ] {
            let decoded = try JSONDecoder().decode(CaptureSource.self, from: JSONEncoder().encode(source))
            XCTAssertEqual(decoded, source)
        }
    }

    func testDisplayIsRestoredOnlyWhenConnected() {
        XCTAssertEqual(CaptureSource.restored(.display(7, name: "Старое имя"), displays: [7: "Студия"], screenFrames: screens), .display(7, name: "Студия"))
        XCTAssertNil(CaptureSource.restored(.display(8, name: "Отключён"), displays: [7: "Студия"], screenFrames: screens))
    }

    func testAreaIsRestoredOnlyInsideAScreen() {
        let inside = CaptureSource.area(NSRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertEqual(CaptureSource.restored(inside, displays: [:], screenFrames: screens), inside)
        XCTAssertNil(CaptureSource.restored(.area(NSRect(x: 2000, y: 100, width: 400, height: 300)), displays: [:], screenFrames: screens))
    }

    func testApplicationIsRestoredAndWindowIsNot() {
        let app = CaptureSource.application(bundleID: "com.apple.Safari", name: "Safari")
        XCTAssertEqual(CaptureSource.restored(app, displays: [:], screenFrames: screens), app)
        XCTAssertNil(CaptureSource.restored(.window(42, name: "Окно"), displays: [:], screenFrames: screens))
        XCTAssertNil(CaptureSource.restored(nil, displays: [:], screenFrames: screens))
    }
}

final class TemporaryFilesTests: XCTestCase {
    func testOnlyRecordingTemporaryFilesAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory
        let ours = folder.appendingPathComponent(RecordingEngine.temporaryPrefix + UUID().uuidString).appendingPathExtension("mov")
        let foreign = folder.appendingPathComponent("not-rec-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: ours.path, contents: Data([1]))
        FileManager.default.createFile(atPath: foreign.path, contents: Data([1]))
        addTeardownBlock { try? FileManager.default.removeItem(at: foreign) }

        RecordingEngine.removeTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ours.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }
}

final class TrackCopyTests: XCTestCase {
    func testSeparateTracksAreCopiedWithoutReencoding() async throws {
        let source = TestMedia.temporaryURL("mov")
        let result = TestMedia.temporaryURL("mp4")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: result)
        }
        try await TestMedia.writeMovie(to: source, audio: [
            .init(channels: 2, planar: true, frequency: 440, spans: [0...3]),
            .init(channels: 1, planar: false, frequency: 660, spans: [0...3])
        ])
        try await AudioMixer.mix(source: source, destination: result)

        var channels: [UInt32] = []
        for track in try await AVURLAsset(url: result).loadTracks(withMediaType: .audio) {
            let format = try await track.load(.formatDescriptions).first
            channels.append(format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0)
        }
        XCTAssertEqual(channels, [2, 2, 1])
    }
}
