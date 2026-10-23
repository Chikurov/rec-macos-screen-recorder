import AVFoundation

final class AudioTrackWriter {
    let input: AVAssetWriterInput
    private(set) var endTime: CMTime?
    private let tolerance = CMTime(value: 20, timescale: 1000)

    init(input: AVAssetWriterInput) {
        self.input = input
    }

    func append(_ buffer: CMSampleBuffer, sessionStart: CMTime) {
        let time = buffer.presentationTimeStamp
        let expected = endTime ?? sessionStart
        guard time >= expected - tolerance else { return }

        if time - expected > tolerance {
            appendSilence(from: expected, to: time, like: buffer)
        }
        guard input.isReadyForMoreMediaData, input.append(buffer) else { return }
        endTime = time + buffer.duration
    }

    private func appendSilence(from start: CMTime, to end: CMTime, like sample: CMSampleBuffer) {
        guard let format = sample.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mSampleRate > 0 else { return }

        let rate = description.mSampleRate
        let isNonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = Int(description.mBytesPerFrame) * (isNonInterleaved ? Int(description.mChannelsPerFrame) : 1)
        var cursor = start

        while cursor < end, input.isReadyForMoreMediaData {
            let frames = min(Int(((end - cursor).seconds * rate).rounded()), Int(rate))
            guard frames > 0 else { break }
            let length = frames * bytesPerFrame

            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: length,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            ) == noErr, let block else { return }
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)

            var silence: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                presentationTimeStamp: cursor, packetDescriptions: nil, sampleBufferOut: &silence
            ) == noErr, let silence, input.append(silence) else { return }

            cursor = cursor + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
            endTime = cursor
        }
    }
}
