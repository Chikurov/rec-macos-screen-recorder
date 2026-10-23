import AVFoundation
import XCTest
@testable import Rec

enum TestMedia {
    static let start = CMTime(value: 1_000_000, timescale: 600)
    static let sampleRate = 48_000.0
    static let chunk = 1024

    struct AudioSource {
        let channels: Int
        let planar: Bool
        let frequency: Double
        let spans: [ClosedRange<Double>]
    }

    static func temporaryURL(_ pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecTests-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    static func sine(_ source: AudioSource, duration: Double = 3) -> [CMSampleBuffer] {
        let frameBytes = source.planar ? 4 : 4 * source.channels
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (source.planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: UInt32(frameBytes), mFramesPerPacket: 1, mBytesPerFrame: UInt32(frameBytes),
            mChannelsPerFrame: UInt32(source.channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        var buffers: [CMSampleBuffer] = []
        for index in 0..<Int(duration * sampleRate) / chunk {
            let time = Double(index * chunk) / sampleRate
            guard source.spans.contains(where: { $0.contains(time) }) else { continue }
            var samples = [Float](repeating: 0, count: chunk * source.channels)
            for frame in 0..<chunk {
                let value = Float(0.3 * sin(2 * .pi * source.frequency * Double(index * chunk + frame) / sampleRate))
                for channel in 0..<source.channels {
                    samples[source.planar ? channel * chunk + frame : frame * source.channels + channel] = value
                }
            }
            let length = samples.count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                presentationTimeStamp: start + CMTime(value: CMTimeValue(index * chunk), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer
            )
            buffers.append(buffer!)
        }
        return buffers
    }

    static func writeMovie(
        to url: URL,
        size: CGSize = CGSize(width: 640, height: 360),
        duration: Double = 3,
        audio: [AudioSource] = []
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var tracks: [(writer: AudioTrackWriter, pending: ArraySlice<CMSampleBuffer>)] = []
        for source in audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEngine.aacSettings(channels: source.channels))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            tracks.append((AudioTrackWriter(input: input), sine(source, duration: duration)[...]))
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: start)

        let frames = Int(duration * 30)
        for frame in 0..<frames {
            let frameTime = start + CMTime(value: CMTimeValue(frame), timescale: 30)
            while !video.isReadyForMoreMediaData { usleep(1000) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer!, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer!), Int32(frame * 3 % 255), CVPixelBufferGetDataSize(pixelBuffer!))
            CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
            adaptor.append(pixelBuffer!, withPresentationTime: frameTime)

            let horizon = frameTime + CMTime(value: 1, timescale: 30)
            for index in tracks.indices {
                while let next = tracks[index].pending.first, next.presentationTimeStamp <= horizon {
                    tracks[index].writer.append(next, sessionStart: start)
                    tracks[index].pending = tracks[index].pending.dropFirst()
                }
            }
        }
        video.markAsFinished()
        tracks.forEach { $0.writer.input.markAsFinished() }
        writer.endSession(atSourceTime: start + CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    static func audibleSpans(of track: AVAssetTrack, in asset: AVAsset) throws -> [ClosedRange<Double>] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
        ])
        reader.add(output)
        reader.startReading()
        var spans: [ClosedRange<Double>] = []
        var current: ClosedRange<Double>?
        while let buffer = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(buffer)
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer!.withMemoryRebound(to: Float.self, capacity: count) { samples in
                for window in stride(from: 0, to: count, by: 480) {
                    var peak: Float = 0
                    for index in window..<min(count, window + 480) { peak = max(peak, abs(samples[index])) }
                    let time = buffer.presentationTimeStamp.seconds + Double(window) / sampleRate
                    if peak > 0.05 {
                        current = (current?.lowerBound ?? time)...time
                    } else if let span = current {
                        spans.append(span)
                        current = nil
                    }
                }
            }
        }
        if let current { spans.append(current) }
        return spans
    }

    static func assertSpans(
        _ actual: [ClosedRange<Double>],
        _ expected: [ClosedRange<Double>],
        tolerance: Double = 0.05,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let describe: ([ClosedRange<Double>]) -> String = { $0.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ") }
        XCTAssertEqual(actual.count, expected.count, "spans \(describe(actual)) vs expected \(describe(expected))", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.lowerBound, e.lowerBound, accuracy: tolerance, "start of \(describe([a]))", file: file, line: line)
            XCTAssertEqual(a.upperBound, min(e.upperBound, 2.99), accuracy: tolerance, "end of \(describe([a]))", file: file, line: line)
        }
    }
}
