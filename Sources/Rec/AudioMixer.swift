import AVFoundation

enum AudioMixer {
    static func mix(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.noFrames
        }
        let formatHint = try await videoTrack.load(.formatDescriptions).first

        let titles = ["Системный звук", "Микрофон"]
        var audioTracks: [(track: AVAssetTrack, title: String)] = []
        for (index, track) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
            if try await track.load(.timeRange).duration > .zero {
                audioTracks.append((track, index < titles.count ? titles[index] : "Звук \(index + 1)"))
            }
        }

        let reader = try AVAssetReader(asset: asset)
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        writer.add(videoInput)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

        if audioTracks.count > 1 {
            pairs.append(addMix(of: audioTracks.map(\.track), reader: reader, writer: writer))
        }
        for entry in audioTracks {
            pairs.append(try await addCopy(of: entry.track, title: entry.title, enabled: audioTracks.count == 1, reader: reader, writer: writer))
        }

        guard reader.startReading(), writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error ?? reader.error)
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (index, pair) in pairs.enumerated() {
                group.addTask { await pump(from: pair.0, to: pair.1, label: "\(index)") }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw RecordingError.writerFailed(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error)
        }
    }

    private static func addMix(of tracks: [AVAssetTrack], reader: AVAssetReader, writer: AVAssetWriter) -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEngine.aacSettings(channels: 2))
        input.metadata = titleMetadata("Микс")
        writer.add(input)
        return (output, input)
    }

    private static func addCopy(
        of track: AVAssetTrack,
        title: String,
        enabled: Bool,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let formatHint = try await track.load(.formatDescriptions).first
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatHint)
        input.marksOutputTrackAsEnabled = enabled
        input.metadata = titleMetadata(title)
        writer.add(input)
        return (output, input)
    }

    private static func titleMetadata(_ title: String) -> [AVMetadataItem] {
        [AVMetadataIdentifier.commonIdentifierTitle, .quickTimeUserDataTrackName].map { identifier in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = title as NSString
            item.extendedLanguageTag = "und"
            return item
        }
    }

    static func pump(from output: AVAssetReaderOutput, to input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "com.chikurov.Rec.mix.\(label)")
        final class PumpState: @unchecked Sendable {
            var finished = false
        }
        let state = PumpState()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !state.finished {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        state.finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
