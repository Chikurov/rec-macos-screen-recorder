import AVFoundation
import XCTest
@testable import Rec

final class AudioPipelineTests: XCTestCase {
    private let system = { (spans: [ClosedRange<Double>]) in
        TestMedia.AudioSource(channels: 2, planar: true, frequency: 440, spans: spans)
    }
    private let microphone = { (spans: [ClosedRange<Double>]) in
        TestMedia.AudioSource(channels: 1, planar: false, frequency: 660, spans: spans)
    }

    private func mixedTracks(system systemSpans: [ClosedRange<Double>], microphone microphoneSpans: [ClosedRange<Double>]) async throws -> (AVURLAsset, [AVAssetTrack]) {
        let source = TestMedia.temporaryURL("mov")
        let result = TestMedia.temporaryURL("mp4")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: result)
        }
        try await TestMedia.writeMovie(to: source, audio: [system(systemSpans), microphone(microphoneSpans)])
        try await AudioMixer.mix(source: source, destination: result)
        let asset = AVURLAsset(url: result)
        return (asset, try await asset.loadTracks(withMediaType: .audio))
    }

    func testBothSourcesProduceMixAndSeparateTracks() async throws {
        let (asset, tracks) = try await mixedTracks(system: [0...3], microphone: [0...3])
        XCTAssertEqual(tracks.count, 3)
        guard tracks.count == 3 else { return }
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.05)
        let videoTrackCount = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(videoTrackCount, 1)

        let enabled = [try await tracks[0].load(.isEnabled), try await tracks[1].load(.isEnabled), try await tracks[2].load(.isEnabled)]
        XCTAssertEqual(enabled, [true, false, false])

        var titles: [String] = []
        for track in tracks {
            let metadata = try await track.load(.metadata)
            let title = try await metadata.first(where: { $0.commonKey == .commonKeyTitle || $0.identifier?.rawValue.hasSuffix("titl") == true })?.load(.stringValue)
            titles.append(title ?? "")
        }
        XCTAssertEqual(titles, ["Микс", "Системный звук", "Микрофон"])
    }

    func testMicrophoneToggledDuringRecordingStaysInSync() async throws {
        let (asset, tracks) = try await mixedTracks(system: [0...3], microphone: [0.5...1.2, 2.0...2.6])
        XCTAssertEqual(tracks.count, 3)
        guard tracks.count == 3 else { return }
        TestMedia.assertSpans(try TestMedia.audibleSpans(of: tracks[2], in: asset), [0.5...1.2, 2.0...2.6])
        TestMedia.assertSpans(try TestMedia.audibleSpans(of: tracks[1], in: asset), [0...3])
    }

    func testMutedSystemAudioStaysInSync() async throws {
        let (asset, tracks) = try await mixedTracks(system: [0...1.0, 2.2...3], microphone: [0...3])
        XCTAssertEqual(tracks.count, 3)
        guard tracks.count == 3 else { return }
        TestMedia.assertSpans(try TestMedia.audibleSpans(of: tracks[1], in: asset), [0...1.0, 2.2...3])
    }

    func testMicrophoneEnabledLateStartsAtTheRightTime() async throws {
        let (asset, tracks) = try await mixedTracks(system: [0...3], microphone: [1.5...3])
        XCTAssertEqual(tracks.count, 3)
        guard tracks.count == 3 else { return }
        TestMedia.assertSpans(try TestMedia.audibleSpans(of: tracks[2], in: asset), [1.5...3])
    }

    func testMixContainsBothSources() async throws {
        let (asset, tracks) = try await mixedTracks(system: [0...1.0], microphone: [2.0...3])
        XCTAssertEqual(tracks.count, 3)
        guard tracks.count == 3 else { return }
        TestMedia.assertSpans(try TestMedia.audibleSpans(of: tracks[0], in: asset), [0...1.0, 2.0...3])
    }

    func testSingleSourceKeepsOneEnabledTrack() async throws {
        let (asset, tracks) = try await mixedTracks(system: [0...3], microphone: [])
        XCTAssertEqual(tracks.count, 1)
        guard tracks.count == 1 else { return }
        let isEnabled = try await tracks[0].load(.isEnabled)
        XCTAssertTrue(isEnabled)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.05)
    }

    func testMicrophoneOnlyKeepsOneEnabledTrack() async throws {
        let (_, tracks) = try await mixedTracks(system: [], microphone: [0...3])
        XCTAssertEqual(tracks.count, 1)
        guard tracks.count == 1 else { return }
        let isEnabled = try await tracks[0].load(.isEnabled)
        XCTAssertTrue(isEnabled)
    }

    func testNoAudioKeepsVideoOnly() async throws {
        let (asset, tracks) = try await mixedTracks(system: [], microphone: [])
        XCTAssertTrue(tracks.isEmpty)
        let videoTrackCount = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(videoTrackCount, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.05)
    }

    func testAudioTrackWriterDropsOverlappingBuffers() async throws {
        let url = TestMedia.temporaryURL("mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEngine.aacSettings(channels: 1))
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: TestMedia.start)

        let track = AudioTrackWriter(input: input)
        let buffers = TestMedia.sine(microphone([0...1]))
        track.append(buffers[0], sessionStart: TestMedia.start)
        track.append(buffers[1], sessionStart: TestMedia.start)
        let endAfterTwo = track.endTime
        track.append(buffers[0], sessionStart: TestMedia.start)
        XCTAssertEqual(track.endTime, endAfterTwo)

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testAudioTrackWriterFillsLeadingGapFromSessionStart() async throws {
        let url = TestMedia.temporaryURL("mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEngine.aacSettings(channels: 1))
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: TestMedia.start)

        let track = AudioTrackWriter(input: input)
        let late = TestMedia.sine(microphone([0.5...0.6]))
        late.forEach { track.append($0, sessionStart: TestMedia.start) }
        XCTAssertNotNil(track.endTime)

        input.markAsFinished()
        await writer.finishWriting()
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let trackStart = try await audio[0].load(.timeRange).start.seconds
        XCTAssertEqual(trackStart, 0, accuracy: 0.01)
        TestMedia.assertSpans(try TestMedia.audibleSpans(of: audio[0], in: asset), [0.5...0.6])
    }
}
