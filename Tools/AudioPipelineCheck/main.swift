import AVFoundation

let workDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let start = CMTime(value: 1_000_000, timescale: 600)
let sampleRate = 48_000.0
var failures = 0

struct Scenario {
    let name: String
    let systemSpans: [ClosedRange<Double>]
    let microphoneSpans: [ClosedRange<Double>]
    let expectedTracks: Int
}

let scenarios = [
    Scenario(name: "both sources, continuous", systemSpans: [0...3], microphoneSpans: [0...3], expectedTracks: 3),
    Scenario(name: "microphone toggled twice", systemSpans: [0...3], microphoneSpans: [0.5...1.2, 2.0...2.6], expectedTracks: 3),
    Scenario(name: "system audio muted mid-way", systemSpans: [0...1.0, 2.2...3], microphoneSpans: [0...3], expectedTracks: 3),
    Scenario(name: "microphone never enabled", systemSpans: [0...3], microphoneSpans: [], expectedTracks: 1)
]

func makeSine(channels: Int, planar: Bool, frequency: Double, spans: [ClosedRange<Double>]) -> [CMSampleBuffer] {
    let frameBytes = planar ? 4 : 4 * channels
    var description = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: UInt32(frameBytes), mFramesPerPacket: 1, mBytesPerFrame: UInt32(frameBytes),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

    let chunk = 1024
    var buffers: [CMSampleBuffer] = []
    for index in 0..<(3 * Int(sampleRate) / chunk) {
        let time = Double(index * chunk) / sampleRate
        guard spans.contains(where: { $0.contains(time) }) else { continue }
        var samples = [Float](repeating: 0, count: chunk * channels)
        for frame in 0..<chunk {
            let value = Float(0.3 * sin(2 * .pi * frequency * Double(index * chunk + frame) / sampleRate))
            for channel in 0..<channels {
                samples[planar ? channel * chunk + frame : frame * channels + channel] = value
            }
        }
        let length = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk, presentationTimeStamp: start + CMTime(value: CMTimeValue(index * chunk), timescale: CMTimeScale(sampleRate)), packetDescriptions: nil, sampleBufferOut: &buffer)
        buffers.append(buffer!)
    }
    return buffers
}

func writeSource(_ scenario: Scenario, to url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360
    ])
    let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEngine.aacSettings(channels: 2))
    let microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEngine.aacSettings(channels: 1))
    for input in [video, systemInput, microphoneInput] {
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    writer.startWriting()
    writer.startSession(atSourceTime: start)

    let systemTrack = AudioTrackWriter(input: systemInput)
    let microphoneTrack = AudioTrackWriter(input: microphoneInput)
    var pendingSystem = makeSine(channels: 2, planar: true, frequency: 440, spans: scenario.systemSpans)[...]
    var pendingMicrophone = makeSine(channels: 1, planar: false, frequency: 660, spans: scenario.microphoneSpans)[...]

    for frame in 0..<90 {
        let frameTime = start + CMTime(value: CMTimeValue(frame), timescale: 30)
        while !video.isReadyForMoreMediaData { usleep(1000) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        adaptor.append(pixelBuffer!, withPresentationTime: frameTime)

        let horizon = frameTime + CMTime(value: 1, timescale: 30)
        while let next = pendingSystem.first, next.presentationTimeStamp <= horizon {
            systemTrack.append(next, sessionStart: start)
            pendingSystem = pendingSystem.dropFirst()
        }
        while let next = pendingMicrophone.first, next.presentationTimeStamp <= horizon {
            microphoneTrack.append(next, sessionStart: start)
            pendingMicrophone = pendingMicrophone.dropFirst()
        }
    }
    [video, systemInput, microphoneInput].forEach { $0.markAsFinished() }
    writer.endSession(atSourceTime: start + CMTime(value: 3, timescale: 1))
    await writer.finishWriting()
}

func audibleSpans(of track: AVAssetTrack, in asset: AVAsset) throws -> [ClosedRange<Double>] {
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

func matches(_ actual: [ClosedRange<Double>], _ expected: [ClosedRange<Double>]) -> Bool {
    actual.count == expected.count && zip(actual, expected).allSatisfy {
        abs($0.lowerBound - $1.lowerBound) < 0.05 && abs($0.upperBound - $1.upperBound) < 0.05
    }
}

func check(_ condition: Bool, _ message: String) {
    print("  \(condition ? "ok  " : "FAIL") \(message)")
    if !condition { failures += 1 }
}

for scenario in scenarios {
    print("• \(scenario.name)")
    let source = workDirectory.appendingPathComponent("audio-check-source.mov")
    let result = workDirectory.appendingPathComponent("audio-check-result.mp4")
    try await writeSource(scenario, to: source)
    try await AudioMixer.mix(source: source, destination: result)

    let asset = AVURLAsset(url: result)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    check(tracks.count == scenario.expectedTracks, "\(tracks.count) audio track(s), expected \(scenario.expectedTracks)")
    check(abs(try await asset.load(.duration).seconds - 3) < 0.05, "duration is 3 s")

    if tracks.count == 3 {
        check(try await tracks[0].load(.isEnabled), "mix track is enabled")
        let systemEnabled = try await tracks[1].load(.isEnabled)
        let microphoneEnabled = try await tracks[2].load(.isEnabled)
        check(!systemEnabled && !microphoneEnabled, "separate tracks are disabled")
        let systemSpans = try audibleSpans(of: tracks[1], in: asset)
        let microphoneSpans = try audibleSpans(of: tracks[2], in: asset)
        check(matches(systemSpans, scenario.systemSpans.map { $0.lowerBound...min($0.upperBound, 2.99) }), "system audio stays in place: \(systemSpans.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) })")
        check(matches(microphoneSpans, scenario.microphoneSpans.map { $0.lowerBound...min($0.upperBound, 2.99) }), "microphone stays in place: \(microphoneSpans.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) })")
    }
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: result)
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
