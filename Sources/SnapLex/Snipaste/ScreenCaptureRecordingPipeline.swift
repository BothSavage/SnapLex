import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Streams ScreenCaptureKit samples straight into an AVAssetWriter so long
/// recordings don't retain uncompressed frames in memory.
final class ScreenCaptureRecordingPipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let outputURL: URL

    var onVideoFrame: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    private let screenRect: CGRect
    private let recordSpeaker: Bool
    private let recordMicrophone: Bool
    private let recordCursor: Bool
    private let recordClick: Bool
    private let recordKeystrokes: Bool
    private let outputQueue = DispatchQueue(label: "io.github.snaplex.recorder.writer", qos: .userInteractive)
    private let imageContext = CIContext(options: [.useSoftwareRenderer: false])

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var speakerInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var writerSessionStart: CMTime?
    private var writerStarted = false
    private var acceptsSamples = true
    private var paused = false
    private var pauseStartedUptime: TimeInterval?
    private var accumulatedPausedTime: TimeInterval = 0
    private var lastKeyLabel: String?
    private var lastKeyUptime: TimeInterval = 0

    init(
        screenRect: CGRect,
        recordSpeaker: Bool,
        recordMicrophone: Bool,
        recordCursor: Bool,
        recordClick: Bool,
        recordKeystrokes: Bool,
        outputURL: URL
    ) {
        self.screenRect = screenRect
        self.recordSpeaker = recordSpeaker
        self.recordMicrophone = recordMicrophone
        self.recordCursor = recordCursor
        self.recordClick = recordClick
        self.recordKeystrokes = recordKeystrokes
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(screenRect) }) ?? NSScreen.main,
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = availableContent.displays.first(where: { $0.displayID == displayNumber.uint32Value }) else {
            throw ScreenCaptureRecordingError.displayUnavailable
        }

        let selectedRect = screenRect.intersection(screen.frame)
        guard !selectedRect.isNull, selectedRect.width >= 32, selectedRect.height >= 32 else {
            throw ScreenCaptureRecordingError.invalidRegion
        }

        let localRect = selectedRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let sourceRect = CGRect(
            x: localRect.minX,
            y: screen.frame.height - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
        let scale = screen.backingScaleFactor
        let outputWidth = max(32, (Int((sourceRect.width * scale).rounded()) / 2) * 2)
        let outputHeight = max(32, (Int((sourceRect.height * scale).rounded()) / 2) * 2)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = outputWidth
        configuration.height = outputHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = recordCursor
        configuration.showMouseClicks = recordClick
        configuration.capturesAudio = recordSpeaker
        configuration.captureMicrophone = recordMicrophone
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.streamName = "SnapLex Screen Recording"

        let ownApplications = availableContent.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )

        try configureWriter(width: outputWidth, height: outputHeight)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if recordSpeaker {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
        if recordMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func setPaused(_ value: Bool) {
        outputQueue.async { [weak self] in
            guard let self, self.paused != value else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.paused = value
            if value {
                self.pauseStartedUptime = now
            } else if let pauseStartedUptime = self.pauseStartedUptime {
                self.accumulatedPausedTime += max(0, now - pauseStartedUptime)
                self.pauseStartedUptime = nil
            }
        }
    }

    func recordKeyOverlay(_ label: String) {
        outputQueue.async { [weak self] in
            guard let self, self.recordKeystrokes else { return }
            self.lastKeyLabel = label
            self.lastKeyUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    func stop() async throws {
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            outputQueue.async { [self] in
                acceptsSamples = false
                guard let writer, writerStarted, writer.status == .writing else {
                    writer?.cancelWriting()
                    continuation.resume(returning: .failure(ScreenCaptureRecordingError.noFrames))
                    return
                }
                videoInput?.markAsFinished()
                speakerInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: .success(()))
                    } else {
                        continuation.resume(returning: .failure(writer.error ?? ScreenCaptureRecordingError.writeFailed))
                    }
                }
            }
        }
        try result.get()
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        await withCheckedContinuation { continuation in
            outputQueue.async { [self] in
                acceptsSamples = false
                writer?.cancelWriting()
                writer = nil
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard acceptsSamples, sampleBuffer.isValid, !paused else { return }

        switch outputType {
        case .screen:
            writeVideo(sampleBuffer)
        case .audio:
            writeAudio(sampleBuffer, input: speakerInput)
        case .microphone:
            writeAudio(sampleBuffer, input: microphoneInput)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(L10n.string("录屏过程中发生错误，请重试。"))
    }

    private func configureWriter(width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(videoInput) else { throw ScreenCaptureRecordingError.writeFailed }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        var speakerInput: AVAssetWriterInput?
        var microphoneInput: AVAssetWriterInput?
        if recordSpeaker {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenCaptureRecordingError.writeFailed }
            writer.add(input)
            speakerInput = input
        }
        if recordMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenCaptureRecordingError.writeFailed }
            writer.add(input)
            microphoneInput = input
        }

        self.writer = writer
        self.videoInput = videoInput
        self.videoAdaptor = adaptor
        self.speakerInput = speakerInput
        self.microphoneInput = microphoneInput
    }

    private func writeVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let input = videoInput,
              let adaptor = videoAdaptor,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time.isValid else { return }
        if !writerStarted {
            guard writer?.startWriting() == true else {
                fail(writer?.error ?? ScreenCaptureRecordingError.writeFailed)
                return
            }
            writer?.startSession(atSourceTime: time)
            writerStarted = true
            writerSessionStart = time
        }
        guard input.isReadyForMoreMediaData else { return }

        var pixelBuffer = sourceBuffer
        if recordKeystrokes, let pool = adaptor.pixelBufferPool {
            var renderedBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &renderedBuffer) == kCVReturnSuccess,
                  let renderedBuffer else { return }
            let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(sourceBuffer), height: CVPixelBufferGetHeight(sourceBuffer))
            imageContext.render(CIImage(cvPixelBuffer: sourceBuffer), to: renderedBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            drawKeyOverlay(on: renderedBuffer)
            pixelBuffer = renderedBuffer
        }

        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            onVideoFrame?()
        } else if let error = writer?.error {
            fail(error)
        }
    }

    private func writeAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard writerStarted,
              let input,
              input.isReadyForMoreMediaData,
              let sessionStart = writerSessionStart else { return }
        let shifted = shiftedSampleBuffer(sampleBuffer)
        let sample = shifted ?? sampleBuffer
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, CMTimeCompare(time, sessionStart) >= 0 else { return }
        if !input.append(sample), let error = writer?.error {
            fail(error)
        }
    }

    private func adjusted(_ time: CMTime) -> CMTime {
        guard time.isValid, accumulatedPausedTime > 0 else { return time }
        return CMTimeSubtract(time, CMTime(seconds: accumulatedPausedTime, preferredTimescale: 1_000_000_000))
    }

    private func shiftedSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard accumulatedPausedTime > 0 else { return nil }
        var needed = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        guard needed > 0 else { return nil }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: needed)
        let status = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: needed,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard status == noErr else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = adjusted(timing[index].presentationTimeStamp)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = adjusted(timing[index].decodeTimeStamp)
            }
        }
        var copy: CMSampleBuffer?
        let copyStatus = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: needed,
                sampleTimingArray: buffer.baseAddress!,
                sampleBufferOut: &copy
            )
        }
        return copyStatus == noErr ? copy : nil
    }

    private func drawKeyOverlay(on pixelBuffer: CVPixelBuffer) {
        guard let label = lastKeyLabel,
              ProcessInfo.processInfo.systemUptime - lastKeyUptime < 1.1,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let scale = CGFloat(width) / max(1, screenRect.width)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 15 * scale, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)
        ]
        guard let attributed = CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent
        let rect = CGRect(
            x: (CGFloat(width) - textWidth) / 2 - 14 * scale,
            y: 24 * scale,
            width: textWidth + 28 * scale,
            height: textHeight + 14 * scale
        )
        let pill = CGPath(roundedRect: rect, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil)
        context.setFillColor(CGColor(gray: 0.06, alpha: 0.78))
        context.addPath(pill)
        context.fillPath()
        context.textPosition = CGPoint(x: rect.minX + 14 * scale, y: rect.minY + 7 * scale + descent)
        CTLineDraw(line, context)
    }

    private func fail(_ error: Error) {
        let message = (error as? ScreenCaptureRecordingError)?.errorDescription
            ?? L10n.string("录屏过程中发生错误，请重试。")
        onFailure?(message)
    }
}

enum ScreenCaptureRecordingError: LocalizedError {
    case displayUnavailable
    case invalidRegion
    case noFrames
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return L10n.string("找不到录制区域所在的显示器。")
        case .invalidRegion: return L10n.string("录制区域太小或不在屏幕范围内。")
        case .noFrames: return L10n.string("没有捕获到可保存的视频帧。")
        case .writeFailed: return L10n.string("无法写入录屏文件。")
        }
    }
}
