import AVFoundation
import XCTest
@testable import Rec

final class PauseTimelineTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func testWithoutPauseTimeIsUnchanged() {
        let timeline = PauseTimeline()
        XCTAssertEqual(timeline.outputTime(for: t(10)), t(10))
        XCTAssertFalse(timeline.isPaused)
    }

    func testBuffersDuringPauseAreDropped() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        XCTAssertTrue(timeline.isPaused)
        XCTAssertNil(timeline.outputTime(for: t(11)))
    }

    func testTimeAfterResumeContinuesWithoutGap() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(15))
        XCTAssertEqual(timeline.pausedTotal, t(5))
        XCTAssertEqual(timeline.outputTime(for: t(15)), t(10))
        XCTAssertEqual(timeline.outputTime(for: t(16)), t(11))
    }

    func testLateBuffersFromBeforeResumeAreDropped() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(15))
        XCTAssertNil(timeline.outputTime(for: t(14.9)))
    }

    func testSeveralPausesAccumulate() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(12))
        timeline.pause(at: t(20))
        timeline.resume(at: t(23))
        XCTAssertEqual(timeline.pausedTotal, t(5))
        XCTAssertEqual(timeline.outputTime(for: t(25)), t(20))
    }

    func testRepeatedPauseOrResumeIsIgnored() {
        var timeline = PauseTimeline()
        timeline.resume(at: t(5))
        XCTAssertEqual(timeline.pausedTotal, .zero)
        timeline.pause(at: t(10))
        timeline.pause(at: t(12))
        timeline.resume(at: t(14))
        XCTAssertEqual(timeline.pausedTotal, t(4))
    }

    func testStopTimeWhilePausedIsThePauseMoment() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(12))
        timeline.pause(at: t(20))
        XCTAssertEqual(timeline.stopTime(now: t(30)), t(18))
    }

    func testStopTimeWhileRecording() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(12))
        XCTAssertEqual(timeline.stopTime(now: t(30)), t(28))
    }
}

final class SampleBufferShiftTests: XCTestCase {
    func testShiftMovesPresentationTimeAndKeepsDuration() throws {
        let buffer = try XCTUnwrap(TestMedia.sine(.init(channels: 2, planar: true, frequency: 440, spans: [0...1])).first)
        let offset = CMTime(seconds: 2.5, preferredTimescale: 600)
        let shifted = try XCTUnwrap(RecordingEngine.shifted(buffer, by: offset))
        XCTAssertEqual(shifted.presentationTimeStamp, buffer.presentationTimeStamp - offset)
        XCTAssertEqual(shifted.duration, buffer.duration)
        XCTAssertEqual(CMSampleBufferGetNumSamples(shifted), CMSampleBufferGetNumSamples(buffer))
    }

    func testShiftAppliesToEveryTimingEntry() throws {
        var timings = (0..<3).map { index in
            CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: CMTimeValue(100 + index), timescale: 30),
                decodeTimeStamp: CMTime(value: CMTimeValue(100 + index), timescale: 30)
            )
        }
        var sizes = [Int](repeating: 1, count: 3)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 3, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 3, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: nil, sampleCount: 3, sampleTimingEntryCount: 3, sampleTimingArray: &timings, sampleSizeEntryCount: 3, sampleSizeArray: &sizes, sampleBufferOut: &buffer)
        let original = try XCTUnwrap(buffer)

        let shifted = try XCTUnwrap(RecordingEngine.shifted(original, by: CMTime(value: 90, timescale: 30)))
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(shifted, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var result = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(shifted, entryCount: count, arrayToFill: &result, entriesNeededOut: &count)
        XCTAssertEqual(result.map(\.presentationTimeStamp), (0..<3).map { CMTime(value: CMTimeValue(10 + $0), timescale: 30) })
        XCTAssertEqual(result.map(\.decodeTimeStamp), (0..<3).map { CMTime(value: CMTimeValue(10 + $0), timescale: 30) })
    }

    func testAACSettings() {
        let mono = RecordingEngine.aacSettings(channels: 1)
        let stereo = RecordingEngine.aacSettings(channels: 2)
        XCTAssertEqual(mono[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(mono[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(stereo[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(stereo[AVSampleRateKey] as? Int, 48_000)
    }
}
