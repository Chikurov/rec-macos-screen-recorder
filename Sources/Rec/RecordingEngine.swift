import AVFoundation
import OSLog
import ScreenCaptureKit

extension Logger {
    static let rec = Logger(subsystem: "com.chikurov.Rec", category: "recording")
}

struct RecordingOptions {
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let pixelSize: CGSize
    let frameRate: Int
    let showsCursor: Bool
    let systemAudio: Bool
    let microphone: AVCaptureDevice?
    let outputURL: URL
}

enum RecordingError: LocalizedError {
    case noFrames
    case writerFailed(Error?)
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "Не получено ни одного кадра. Проверьте разрешение «Запись экрана»."
        case .writerFailed(let error):
            return "Не удалось записать файл: \(error?.localizedDescription ?? "неизвестная ошибка")"
        case .microphoneUnavailable:
            return "Не удалось подключить микрофон."
        }
    }
}

final class RecordingEngine: NSObject {
    var onStreamStopped: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.chikurov.Rec.engine")
    private let microphoneQueue = DispatchQueue(label: "com.chikurov.Rec.microphone")
    private let hostClock = CMClockGetHostTimeClock()

    private var options: RecordingOptions?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerURL: URL?
    private var isSystemAudioMuted = false
    private var videoInput: AVAssetWriterInput?
    private var systemAudioTrack: AudioTrackWriter?
    private var microphoneTrack: AudioTrackWriter?
    private var microphoneSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?

    private var sessionStartTime: CMTime?
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastVideoTime = CMTime.negativeInfinity
    private var isPaused = false
    private var pauseStartedAt: CMTime?
    private var resumedAt = CMTime.zero
    private var pausedTotal = CMTime.zero

    func start(_ options: RecordingOptions) async throws {
        self.options = options
        isSystemAudioMuted = !options.systemAudio
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        writerURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(for: options))
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        self.videoInput = videoInput

        let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2))
        systemInput.expectsMediaDataInRealTime = true
        writer.add(systemInput)
        systemAudioTrack = AudioTrackWriter(input: systemInput)

        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1))
        micInput.expectsMediaDataInRealTime = true
        writer.add(micInput)
        microphoneTrack = AudioTrackWriter(input: micInput)

        guard writer.startWriting() else { throw RecordingError.writerFailed(writer.error) }
        self.writer = writer

        let configuration = SCStreamConfiguration()
        configuration.width = Int(options.pixelSize.width)
        configuration.height = Int(options.pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        configuration.showsCursor = options.showsCursor
        configuration.queueDepth = 6
        configuration.colorSpaceName = CGColorSpace.sRGB
        if let sourceRect = options.sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: options.filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream

        if let microphone = options.microphone {
            try setMicrophone(microphone)
        }

        try await stream.startCapture()
        Logger.rec.info("capture started \(Int(options.pixelSize.width))x\(Int(options.pixelSize.height)) fps=\(options.frameRate) system=\(options.systemAudio) mic=\(options.microphone != nil)")
    }

    func pause() {
        queue.async { [self] in
            guard !isPaused else { return }
            isPaused = true
            pauseStartedAt = CMClockGetTime(hostClock)
        }
    }

    func resume() {
        queue.async { [self] in
            guard isPaused else { return }
            let now = CMClockGetTime(hostClock)
            if let pauseStartedAt {
                pausedTotal = pausedTotal + (now - pauseStartedAt)
            }
            pauseStartedAt = nil
            resumedAt = now
            isPaused = false
        }
    }

    func setSystemAudioMuted(_ muted: Bool) {
        queue.async { [self] in
            isSystemAudioMuted = muted
        }
    }

    func setMicrophone(_ device: AVCaptureDevice?) throws {
        guard let device else {
            replaceMicrophone(with: nil, output: nil)
            return
        }

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            throw RecordingError.microphoneUnavailable
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        replaceMicrophone(with: session, output: output)
        microphoneQueue.async { session.startRunning() }
    }

    private func replaceMicrophone(with session: AVCaptureSession?, output: AVCaptureAudioDataOutput?) {
        let previous: AVCaptureSession? = queue.sync {
            let previous = microphoneSession
            microphoneSession = session
            microphoneOutput = output
            return previous
        }
        if let previous {
            microphoneQueue.async { previous.stopRunning() }
        }
    }

    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        try? setMicrophone(nil)

        let writer = try await finishWriter()
        guard let options, let writerURL else { throw RecordingError.writerFailed(nil) }

        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error)
        }

        defer { try? FileManager.default.removeItem(at: writerURL) }
        try await AudioMixer.mix(source: writerURL, destination: options.outputURL)
        Logger.rec.info("recording saved")
        return options.outputURL
    }

    // MARK: - Writing

    private func finishWriter() async throws -> AVAssetWriter {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAssetWriter, Error>) in
            queue.async { [self] in
                guard let writer else {
                    continuation.resume(throwing: RecordingError.writerFailed(nil))
                    return
                }
                guard sessionStartTime != nil, let lastVideoBuffer else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecordingError.noFrames)
                    return
                }

                let stopTime = (pauseStartedAt ?? CMClockGetTime(hostClock)) - pausedTotal
                if stopTime > lastVideoTime,
                   let videoInput, videoInput.isReadyForMoreMediaData,
                   let finalFrame = Self.shifted(lastVideoBuffer, by: lastVideoBuffer.presentationTimeStamp - stopTime) {
                    videoInput.append(finalFrame)
                    lastVideoTime = stopTime
                }

                videoInput?.markAsFinished()
                systemAudioTrack?.input.markAsFinished()
                microphoneTrack?.input.markAsFinished()
                writer.endSession(atSourceTime: lastVideoTime)
                writer.finishWriting {
                    continuation.resume(returning: writer)
                }
            }
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let videoInput, !isPaused, writer.status == .writing else { return }
        let originalTime = sampleBuffer.presentationTimeStamp
        guard originalTime >= resumedAt else { return }

        let time = originalTime - pausedTotal
        if sessionStartTime == nil {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
        }
        guard time > lastVideoTime, videoInput.isReadyForMoreMediaData,
              let buffer = pausedTotal == .zero ? sampleBuffer : Self.shifted(sampleBuffer, by: pausedTotal) else { return }

        if videoInput.append(buffer) {
            lastVideoTime = time
            lastVideoBuffer = buffer
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackWriter?, clockOffset: CMTime = .zero) {
        guard let track, let writer, let sessionStartTime, !isPaused, writer.status == .writing else { return }
        let hostTime = sampleBuffer.presentationTimeStamp - clockOffset
        guard hostTime >= resumedAt, hostTime - pausedTotal >= sessionStartTime else { return }

        let offset = clockOffset + pausedTotal
        guard let buffer = offset == .zero ? sampleBuffer : Self.shifted(sampleBuffer, by: offset) else { return }
        track.append(buffer, sessionStart: sessionStartTime)
    }

    private func videoSettings(for options: RecordingOptions) -> [String: Any] {
        let width = Int(options.pixelSize.width)
        let height = Int(options.pixelSize.height)
        let bitRate = max(2_000_000, Int(Double(width * height * options.frameRate) * 0.1))
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: options.frameRate,
                AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }

    static func aacSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
        ]
    }

    static func shifted(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - offset
            }
        }
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &result
        )
        return result
    }
}

extension RecordingEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete else { return }
            handleVideo(sampleBuffer)
        case .audio:
            guard !isSystemAudioMuted else { return }
            handleAudio(sampleBuffer, track: systemAudioTrack)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.rec.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onStreamStopped?(error)
        }
    }
}

extension RecordingEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === microphoneOutput, let clock = microphoneSession?.synchronizationClock else { return }
        let time = sampleBuffer.presentationTimeStamp
        let hostTime = CMSyncConvertTime(time, from: clock, to: hostClock)
        handleAudio(sampleBuffer, track: microphoneTrack, clockOffset: time - hostTime)
    }
}
