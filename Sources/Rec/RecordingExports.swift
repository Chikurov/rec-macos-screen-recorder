import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum RecordingExports {
    struct CompressedPreset {
        let label: String
        let maxSize: CGSize
        let videoBitRate: Int
    }

    static let compressedPresets = [
        CompressedPreset(label: "1080p", maxSize: CGSize(width: 1920, height: 1080), videoBitRate: 5_000_000),
        CompressedPreset(label: "720p", maxSize: CGSize(width: 1280, height: 720), videoBitRate: 2_500_000)
    ]
    static let compressedAudioBitRate = 128_000

    static func uniqueURL(in folder: URL, base: String, extension pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(pathExtension)
            index += 1
        }
        return candidate
    }

    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        if first.standardizedFileURL.resolvingSymlinksInPath().path == second.standardizedFileURL.resolvingSymlinksInPath().path {
            return true
        }
        guard let firstID = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let secondID = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return firstID.isEqual(secondID)
    }

    static func estimatedCompressedSize(duration: Double, preset: CompressedPreset) -> Int64 {
        Int64(Double(preset.videoBitRate + compressedAudioBitRate) * duration / 8)
    }

    static func fittedSize(_ size: CGSize, into bounds: CGSize) -> CGSize {
        let landscape = size.width >= size.height
        let limit = landscape ? bounds : CGSize(width: bounds.height, height: bounds.width)
        let factor = min(1, limit.width / size.width, limit.height / size.height)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * factor / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    static func exportCompressedCopy(of url: URL, to output: URL, preset: CompressedPreset) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureSetupError("В файле нет видео.")
        }
        var mixTrack: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .audio) where try await track.load(.isEnabled) {
            mixTrack = track
            break
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let size = fittedSize(naturalSize, into: preset.maxSize)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

        if let mixTrack {
            let audioOutput = AVAssetReaderTrackOutput(track: mixTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(audioOutput)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: compressedAudioBitRate
            ])
            writer.add(audioInput)
            pairs.append((audioOutput, audioInput))
        }

        guard reader.startReading(), writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error ?? reader.error)
        }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for (index, pair) in pairs.enumerated() {
                group.addTask { await AudioMixer.pump(from: pair.0, to: pair.1, label: "compress\(index)") }
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw RecordingError.writerFailed(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw RecordingError.writerFailed(writer.error)
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
