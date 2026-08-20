import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Darwin

// MARK: - Values shared with the GIF recording coordinator

/// A crop in the selected display's ScreenCaptureKit coordinate space.
/// `sourceRect` is expressed in display points, with the origin expected by
/// `SCStreamConfiguration.sourceRect`. `backingScaleFactor` converts those
/// points into source pixels before the 1280-pixel recording cap is applied.
struct GIFCaptureRegion: Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let backingScaleFactor: CGFloat

    init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        backingScaleFactor: CGFloat
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.backingScaleFactor = backingScaleFactor
    }
}

struct GIFFrameStatistics: Codable, Equatable, Sendable {
    let received: Int
    let appended: Int
    let dropped: Int
    let synthetic: Int
    let idle: Int
    let invalid: Int
    let backpressure: Int
    let appendFailed: Int
}

struct GIFRecordingInfo: Sendable {
    let sessionID: UUID
    let region: GIFCaptureRegion
    let outputPixelSize: CGSize
    let movieURL: URL
    let startedAt: Date
}

struct GIFMovieRecording: Sendable {
    let info: GIFRecordingInfo
    let duration: TimeInterval
    let movieBytes: Int64
    let frames: GIFFrameStatistics
}

/// A half-open time range used while sampling the intermediate movie.
///
/// Callers may construct a range before the movie's exact duration is known.
/// `normalized(forDuration:)` clamps both endpoints to the asset and rejects
/// ranges that are reversed, non-finite, or too short to produce a useful GIF.
struct GIFTrimRange: Equatable, Sendable {
    static let minimumDuration: TimeInterval = 0.1

    let start: TimeInterval
    let end: TimeInterval

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    var duration: TimeInterval {
        guard start.isFinite, end.isFinite else { return 0 }
        return max(0, end - start)
    }

    var isValid: Bool {
        start.isFinite
            && end.isFinite
            && start >= 0
            && end > start
            && duration >= Self.minimumDuration
    }

    func normalized(forDuration assetDuration: TimeInterval) -> GIFTrimRange? {
        guard assetDuration.isFinite,
              assetDuration > 0,
              start.isFinite,
              end.isFinite,
              end > start else {
            return nil
        }
        let normalized = GIFTrimRange(
            start: min(max(0, start), assetDuration),
            end: min(max(0, end), assetDuration)
        )
        return normalized.isValid ? normalized : nil
    }
}

/// Pure frame scheduling logic shared by every encoder quality attempt.
/// Keeping this independent from AVFoundation makes trim clamping, frame count,
/// sample positions, and the shortened final-frame delay straightforward to test.
struct GIFFrameSchedule: Equatable, Sendable {
    let range: GIFTrimRange
    let frameRate: Int
    let frameCount: Int

    init?(
        trimRange: GIFTrimRange?,
        assetDuration: TimeInterval,
        frameRate: Int
    ) {
        guard assetDuration.isFinite,
              assetDuration > 0,
              frameRate > 0 else {
            return nil
        }

        let effectiveRange: GIFTrimRange
        if let trimRange {
            guard let normalized = trimRange.normalized(forDuration: assetDuration) else {
                return nil
            }
            effectiveRange = normalized
        } else {
            effectiveRange = GIFTrimRange(start: 0, end: assetDuration)
        }

        // Avoid manufacturing an empty trailing frame when a mathematically
        // integral duration lands a few ULPs above the integer boundary.
        let scaledFrameCount = effectiveRange.duration * Double(frameRate)
        let rawFrameCount = ceil(max(0, scaledFrameCount - 1e-9))
        guard rawFrameCount.isFinite,
              rawFrameCount > 0,
              rawFrameCount < Double(Int.max) else {
            return nil
        }
        range = effectiveRange
        self.frameRate = frameRate
        frameCount = max(1, Int(rawFrameCount))
    }

    func sampleTime(forFrame index: Int) -> TimeInterval? {
        guard (0..<frameCount).contains(index) else { return nil }
        let requestedTime = range.start + Double(index) / Double(frameRate)
        // The schedule is half-open. This guard also protects against floating
        // point rounding placing the final request exactly on the end boundary.
        return min(requestedTime, range.end.nextDown)
    }

    func frameDelay(forFrame index: Int) -> TimeInterval? {
        guard (0..<frameCount).contains(index) else { return nil }
        let frameDuration = 1 / Double(frameRate)
        let elapsed = Double(index) * frameDuration
        return min(frameDuration, max(0, range.duration - elapsed))
    }
}

struct GIFEncodingAttempt: Codable, Equatable, Sendable {
    let frameRate: Int
    let maxDimension: Int
    let outputPixelSize: CGSize
    let gifBytes: Int64
    let wallTime: TimeInterval
    let cpuTime: TimeInterval
}

struct GIFEncodingResult: Sendable {
    let sessionID: UUID
    let data: Data
    let fileURL: URL
    let outputPixelSize: CGSize
    let frameRate: Int
    let duration: TimeInterval
    let gifBytes: Int64
    let attempts: [GIFEncodingAttempt]
    let encodingWallTime: TimeInterval
    let encodingCPUTime: TimeInterval
    let exceedsMaximumBytes: Bool
}

enum GIFExperimentStage: String, Codable, Sendable {
    case selection
    case recordingSetup = "recording_setup"
    case recording
    case recordingStop = "recording_stop"
    case encoding
    case clipboard
    case upload
}

enum GIFMediaPipelineError: LocalizedError, Sendable {
    case invalidRegion
    case invalidTrimRange
    case displayNotFound
    case startInProgress
    case alreadyRecording
    case notRecording
    case unableToCreateTemporaryDirectory
    case unableToCreateAssetWriter
    case unableToConfigureAssetWriter
    case unableToStartAssetWriter
    case noVideoFrames
    case screenCaptureStopped(domain: String, code: Int)
    case assetWriterFailed(domain: String, code: Int)
    case unreadableMovie
    case unableToCreateGIF
    case unableToReadGIF

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            return "The selected GIF recording region is invalid."
        case .invalidTrimRange:
            return "The selected GIF time range is invalid or too short."
        case .displayNotFound:
            return "The selected display is no longer available."
        case .startInProgress:
            return "GIF recording is still starting."
        case .alreadyRecording:
            return "A GIF recording is already active."
        case .notRecording:
            return "No GIF recording is active."
        case .unableToCreateTemporaryDirectory:
            return "The temporary GIF recording directory could not be created."
        case .unableToCreateAssetWriter:
            return "The temporary screen recording could not be created."
        case .unableToConfigureAssetWriter:
            return "The temporary screen recording encoder could not be configured."
        case .unableToStartAssetWriter:
            return "The temporary screen recording encoder could not be started."
        case .noVideoFrames:
            return "No screen frames were recorded."
        case .screenCaptureStopped:
            return "Screen recording stopped unexpectedly."
        case .assetWriterFailed:
            return "The temporary screen recording could not be finalized."
        case .unreadableMovie:
            return "The temporary screen recording could not be read."
        case .unableToCreateGIF:
            return "The GIF encoder could not create an output file."
        case .unableToReadGIF:
            return "The encoded GIF could not be read."
        }
    }

    var diagnosticKind: String {
        switch self {
        case .invalidRegion: return "invalid_region"
        case .invalidTrimRange: return "invalid_trim_range"
        case .displayNotFound: return "display_not_found"
        case .startInProgress: return "start_in_progress"
        case .alreadyRecording: return "already_recording"
        case .notRecording: return "not_recording"
        case .unableToCreateTemporaryDirectory: return "temporary_directory"
        case .unableToCreateAssetWriter: return "asset_writer_create"
        case .unableToConfigureAssetWriter: return "asset_writer_configure"
        case .unableToStartAssetWriter: return "asset_writer_start"
        case .noVideoFrames: return "no_video_frames"
        case .screenCaptureStopped: return "screen_capture_stopped"
        case .assetWriterFailed: return "asset_writer_failed"
        case .unreadableMovie: return "unreadable_movie"
        case .unableToCreateGIF: return "gif_create"
        case .unableToReadGIF: return "gif_read"
        }
    }
}

// MARK: - ScreenCaptureKit -> H.264 MOV

actor ScreenStreamRecorder {
    typealias UnexpectedStopHandler = @Sendable (Error) -> Void

    private enum State {
        case idle
        case starting
        case recording(ActiveRecording)
        case stopping
    }

    private final class ActiveRecording: @unchecked Sendable {
        let info: GIFRecordingInfo
        let stream: SCStream
        let output: GIFStreamOutput

        init(info: GIFRecordingInfo, stream: SCStream, output: GIFStreamOutput) {
            self.info = info
            self.stream = stream
            self.output = output
        }
    }

    private let onUnexpectedStop: UnexpectedStopHandler?
    private var state: State = .idle
    private var cancelStartRequested = false
    private var cancelStopRequested = false

    init(onUnexpectedStop: UnexpectedStopHandler? = nil) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func start(region: GIFCaptureRegion, sessionID: UUID) async throws -> GIFRecordingInfo {
        switch state {
        case .idle:
            break
        case .starting:
            throw GIFMediaPipelineError.startInProgress
        case .recording, .stopping:
            throw GIFMediaPipelineError.alreadyRecording
        }

        guard Self.isValid(region) else {
            GIFExperimentLogger.recordError(
                sessionID: sessionID,
                stage: .recordingSetup,
                error: GIFMediaPipelineError.invalidRegion
            )
            throw GIFMediaPipelineError.invalidRegion
        }

        state = .starting
        cancelStartRequested = false
        cancelStopRequested = false

        let outputSize = Self.outputPixelSize(for: region)
        GIFExperimentLogger.recordRecordingAttempt(
            sessionID: sessionID,
            region: region,
            outputPixelSize: outputSize
        )
        var createdOutput: GIFStreamOutput?
        var createdStream: SCStream?
        do {
            let movieURL = try GIFTemporaryFiles.makeURL(
                sessionID: sessionID,
                kind: "recording",
                pathExtension: "mov"
            )
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            try checkStartCancellation()

            guard let display = content.displays.first(where: {
                $0.displayID == region.displayID
            }) else {
                throw GIFMediaPipelineError.displayNotFound
            }

            let currentProcessID = ProcessInfo.processInfo.processIdentifier
            let ownApplications = content.applications.filter {
                $0.processID == currentProcessID
            }
            let filter: SCContentFilter
            if !ownApplications.isEmpty {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApplications,
                    exceptingWindows: []
                )
            } else {
                // This is only a fallback for the unlikely case that the current
                // process has not yet appeared in `applications`.
                let ownWindows = content.windows.filter {
                    $0.owningApplication?.processID == currentProcessID
                }
                filter = SCContentFilter(
                    display: display,
                    excludingWindows: ownWindows
                )
            }

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = region.sourceRect
            configuration.width = Int(outputSize.width)
            configuration.height = Int(outputSize.height)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            configuration.queueDepth = 5
            configuration.showsCursor = true
            configuration.capturesAudio = false

            let startedAt = Date()
            let info = GIFRecordingInfo(
                sessionID: sessionID,
                region: region,
                outputPixelSize: outputSize,
                movieURL: movieURL,
                startedAt: startedAt
            )
            let output = try GIFStreamOutput(
                movieURL: movieURL,
                outputPixelSize: outputSize,
                frameRate: 10,
                onUnexpectedStop: { [onUnexpectedStop] error in
                    GIFExperimentLogger.recordError(
                        sessionID: sessionID,
                        stage: .recording,
                        error: error,
                        region: region,
                        outputPixelSize: outputSize
                    )
                    onUnexpectedStop?(error)
                }
            )
            createdOutput = output

            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: output
            )
            createdStream = stream
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: output.sampleQueue
            )
            try checkStartCancellation()
            try await stream.startCapture()
            try checkStartCancellation()

            state = .recording(
                ActiveRecording(info: info, stream: stream, output: output)
            )
            GIFExperimentLogger.recordSessionStarted(info)
            return info
        } catch {
            if let stream = createdStream {
                try? await stream.stopCapture()
                if let output = createdOutput {
                    try? stream.removeStreamOutput(output, type: .screen)
                }
            }
            createdOutput?.cancel(removeMovie: true)
            state = .idle
            cancelStartRequested = false
            cancelStopRequested = false
            if !(error is CancellationError) {
                GIFExperimentLogger.recordError(
                    sessionID: sessionID,
                    stage: .recordingSetup,
                    error: error,
                    region: region,
                    outputPixelSize: outputSize
                )
            }
            throw error
        }
    }

    func stop() async throws -> GIFMovieRecording {
        let active: ActiveRecording
        switch state {
        case .recording(let value):
            active = value
        case .starting:
            throw GIFMediaPipelineError.startInProgress
        case .idle, .stopping:
            throw GIFMediaPipelineError.notRecording
        }

        state = .stopping
        cancelStopRequested = false
        active.output.expectStop()
        var stopError: Error?
        do {
            try await active.stream.stopCapture()
        } catch {
            stopError = error
        }
        try? active.stream.removeStreamOutput(active.output, type: .screen)

        do {
            let summary = try await active.output.finish()
            if cancelStopRequested || Task.isCancelled {
                throw CancellationError()
            }
            state = .idle
            cancelStartRequested = false
            cancelStopRequested = false

            if let stopError {
                throw stopError
            }

            let movie = GIFMovieRecording(
                info: active.info,
                duration: summary.duration,
                movieBytes: Self.fileSize(at: active.info.movieURL),
                frames: summary.frames
            )
            GIFExperimentLogger.recordRecording(movie)
            return movie
        } catch {
            state = .idle
            cancelStartRequested = false
            cancelStopRequested = false
            try? FileManager.default.removeItem(at: active.info.movieURL)
            if !(error is CancellationError) {
                GIFExperimentLogger.recordError(
                    sessionID: active.info.sessionID,
                    stage: .recordingStop,
                    error: error,
                    region: active.info.region,
                    outputPixelSize: active.info.outputPixelSize
                )
            }
            throw error
        }
    }

    func cancel() async {
        switch state {
        case .idle:
            return
        case .starting:
            cancelStartRequested = true
        case .recording(let active):
            state = .stopping
            cancelStopRequested = true
            active.output.expectStop()
            try? await active.stream.stopCapture()
            try? active.stream.removeStreamOutput(active.output, type: .screen)
            active.output.cancel(removeMovie: true)
            state = .idle
        case .stopping:
            // `stop()` owns the stream and writer while awaiting their async
            // completion. It observes this flag before returning and removes
            // the movie instead of handing it to the encoder.
            cancelStopRequested = true
        }
    }

    private func checkStartCancellation() throws {
        try Task.checkCancellation()
        if cancelStartRequested {
            throw CancellationError()
        }
    }

    private static func isValid(_ region: GIFCaptureRegion) -> Bool {
        let rect = region.sourceRect
        return rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && region.backingScaleFactor.isFinite
            && rect.minX >= 0
            && rect.minY >= 0
            && rect.width >= 2
            && rect.height >= 2
            && region.backingScaleFactor > 0
    }

    private static func outputPixelSize(for region: GIFCaptureRegion) -> CGSize {
        let sourceWidth = region.sourceRect.width * region.backingScaleFactor
        let sourceHeight = region.sourceRect.height * region.backingScaleFactor
        let reduction = min(1, 1280 / max(sourceWidth, sourceHeight))
        return CGSize(
            width: evenPixelDimension(sourceWidth * reduction),
            height: evenPixelDimension(sourceHeight * reduction)
        )
    }

    private static func evenPixelDimension(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int(value.rounded(.down)) / 2 * 2))
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private final class GIFStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Summary: Sendable {
        let duration: TimeInterval
        let frames: GIFFrameStatistics
    }

    let sampleQueue = DispatchQueue(
        label: "com.gmch.pocketimg.shot.gif-recording",
        qos: .userInitiated
    )

    private let movieURL: URL
    private let frameRate: Int
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let onUnexpectedStop: @Sendable (Error) -> Void
    private let stateLock = NSLock()

    private var receivedFrames = 0
    private var appendedFrames = 0
    private var droppedFrames = 0
    private var syntheticFrames = 0
    private var idleFrames = 0
    private var invalidFrames = 0
    private var backpressureFrames = 0
    private var appendFailedFrames = 0
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var firstFrameUptime: TimeInterval?
    private var stopRequestedUptime: TimeInterval?
    private var lastAppendedSampleBuffer: CMSampleBuffer?
    private var expectedStop = false
    private var streamError: Error?
    private var reportedTerminalError = false
    private var finalized = false

    init(
        movieURL: URL,
        outputPixelSize: CGSize,
        frameRate: Int,
        onUnexpectedStop: @escaping @Sendable (Error) -> Void
    ) throws {
        self.movieURL = movieURL
        self.frameRate = frameRate
        self.onUnexpectedStop = onUnexpectedStop

        do {
            writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        } catch {
            throw GIFMediaPipelineError.unableToCreateAssetWriter
        }

        let width = Int(outputPixelSize.width)
        let height = Int(outputPixelSize.height)
        let bitsPerPixel = 5.5
        let estimatedBitRate = max(
            1_000_000,
            min(10_000_000, Int(Double(width * height) * bitsPerPixel))
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: estimatedBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = true

        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video),
              writer.canAdd(writerInput) else {
            throw GIFMediaPipelineError.unableToConfigureAssetWriter
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw GIFMediaPipelineError.unableToStartAssetWriter
        }
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        receivedFrames += 1

        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let status = frameStatus(sampleBuffer) else {
            droppedFrames += 1
            invalidFrames += 1
            return
        }
        if status == .idle {
            idleFrames += 1
            return
        }
        guard (status == .started || status == .complete),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            droppedFrames += 1
            invalidFrames += 1
            return
        }
        guard writer.status == .writing else {
            droppedFrames += 1
            appendFailedFrames += 1
            if writer.status == .failed {
                captureWriterErrorIfNeeded()
            }
            return
        }
        guard writerInput.isReadyForMoreMediaData else {
            droppedFrames += 1
            backpressureFrames += 1
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, !presentationTime.isIndefinite else {
            droppedFrames += 1
            invalidFrames += 1
            return
        }
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            firstFrameUptime = ProcessInfo.processInfo.systemUptime
            writer.startSession(atSourceTime: presentationTime)
        }

        if writerInput.append(sampleBuffer) {
            appendedFrames += 1
            lastPresentationTime = presentationTime
            lastAppendedSampleBuffer = sampleBuffer
        } else {
            droppedFrames += 1
            appendFailedFrames += 1
            captureWriterErrorIfNeeded()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        streamError = error
        let shouldReport = !expectedStop && !reportedTerminalError
        if shouldReport {
            reportedTerminalError = true
        }
        stateLock.unlock()

        if shouldReport {
            onUnexpectedStop(error)
        }
    }

    func expectStop() {
        stateLock.lock()
        expectedStop = true
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        stateLock.unlock()
    }

    func finish() async throws -> Summary {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                guard !finalized else {
                    continuation.resume(throwing: GIFMediaPipelineError.notRecording)
                    return
                }
                finalized = true

                guard appendedFrames > 0,
                      let firstPresentationTime,
                      let lastPresentationTime else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: movieURL)
                    continuation.resume(throwing: GIFMediaPipelineError.noVideoFrames)
                    return
                }

                let endTime = appendTerminalFrameAndResolveEndTime(
                    firstPresentationTime: firstPresentationTime,
                    lastPresentationTime: lastPresentationTime
                )
                writerInput.markAsFinished()
                writer.endSession(atSourceTime: endTime)
                writer.finishWriting { [self] in
                    sampleQueue.async {
                        if let streamError = lockedStreamError() {
                            try? FileManager.default.removeItem(at: movieURL)
                            continuation.resume(
                                throwing: Self.pipelineError(forScreenCaptureError: streamError)
                            )
                            return
                        }
                        guard writer.status == .completed else {
                            try? FileManager.default.removeItem(at: movieURL)
                            continuation.resume(
                                throwing: Self.pipelineError(forWriterError: writer.error)
                            )
                            return
                        }

                        let elapsed = CMTimeGetSeconds(
                            CMTimeSubtract(endTime, firstPresentationTime)
                        )
                        let duration = elapsed.isFinite
                            ? max(1 / Double(frameRate), elapsed)
                            : max(1 / Double(frameRate), Double(appendedFrames) / Double(frameRate))
                        continuation.resume(
                            returning: Summary(
                                duration: duration,
                                frames: GIFFrameStatistics(
                                    received: receivedFrames,
                                    appended: appendedFrames,
                                    dropped: droppedFrames,
                                    synthetic: syntheticFrames,
                                    idle: idleFrames,
                                    invalid: invalidFrames,
                                    backpressure: backpressureFrames,
                                    appendFailed: appendFailedFrames
                                )
                            )
                        )
                    }
                }
            }
        }
    }

    func cancel(removeMovie: Bool) {
        stateLock.lock()
        expectedStop = true
        stateLock.unlock()
        sampleQueue.async { [self] in
            guard !finalized else { return }
            finalized = true
            writerInput.markAsFinished()
            writer.cancelWriting()
            if removeMovie {
                try? FileManager.default.removeItem(at: movieURL)
            }
        }
    }

    private func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? NSNumber,
        let status = SCFrameStatus(rawValue: rawStatus.intValue) else {
            return nil
        }
        return status
    }

    private func appendTerminalFrameAndResolveEndTime(
        firstPresentationTime: CMTime,
        lastPresentationTime: CMTime
    ) -> CMTime {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let requestedUptime = lockedStopRequestedUptime()
        let wallDuration = max(
            0,
            (requestedUptime ?? ProcessInfo.processInfo.systemUptime)
                - (firstFrameUptime ?? ProcessInfo.processInfo.systemUptime)
        )
        let minimumDuration = 2 / Double(frameRate)
        let wallEndTime = CMTimeAdd(
            firstPresentationTime,
            CMTime(seconds: max(minimumDuration, wallDuration), preferredTimescale: 600)
        )
        let endTime = CMTimeMaximum(
            wallEndTime,
            CMTimeAdd(lastPresentationTime, frameDuration)
        )
        let terminalPresentationTime = CMTimeSubtract(endTime, frameDuration)

        guard CMTimeCompare(terminalPresentationTime, lastPresentationTime) > 0,
              let lastAppendedSampleBuffer,
              writerInput.isReadyForMoreMediaData,
              let terminalSample = retimedCopy(
                of: lastAppendedSampleBuffer,
                presentationTime: terminalPresentationTime,
                duration: frameDuration
              ),
              writerInput.append(terminalSample) else {
            return endTime
        }

        syntheticFrames += 1
        appendedFrames += 1
        self.lastPresentationTime = terminalPresentationTime
        self.lastAppendedSampleBuffer = terminalSample
        return endTime
    }

    private func retimedCopy(
        of sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    private func captureWriterErrorIfNeeded() {
        guard let error = writer.error else { return }
        stateLock.lock()
        let shouldReport = !expectedStop && !reportedTerminalError
        if shouldReport {
            reportedTerminalError = true
        }
        stateLock.unlock()
        if shouldReport {
            onUnexpectedStop(error)
        }
    }

    private func lockedStreamError() -> Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamError
    }

    private func lockedStopRequestedUptime() -> TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequestedUptime
    }

    private static func pipelineError(forScreenCaptureError error: Error) -> Error {
        let value = error as NSError
        return GIFMediaPipelineError.screenCaptureStopped(
            domain: value.domain,
            code: value.code
        )
    }

    private static func pipelineError(forWriterError error: Error?) -> Error {
        let value = error as NSError?
        return GIFMediaPipelineError.assetWriterFailed(
            domain: value?.domain ?? AVFoundationErrorDomain,
            code: value?.code ?? -1
        )
    }
}

// MARK: - MOV -> looping GIF

actor GIFEncoder {
    private struct Policy: Sendable {
        let frameRate: Int
        let maxDimension: Int
    }

    private struct AttemptOutput: Sendable {
        let url: URL
        let outputPixelSize: CGSize
        let duration: TimeInterval
        let bytes: Int64
        let wallTime: TimeInterval
        let cpuTime: TimeInterval
    }

    private let maximumBytes: Int64
    private let policies = [
        Policy(frameRate: 10, maxDimension: 1280),
        Policy(frameRate: 8, maxDimension: 960),
        Policy(frameRate: 6, maxDimension: 720)
    ]

    init(maximumBytes: Int64 = 24 * 1024 * 1024) {
        self.maximumBytes = maximumBytes
    }

    func encode(
        movie: GIFMovieRecording,
        sessionID: UUID,
        trimRange: GIFTrimRange? = nil
    ) async throws -> GIFEncodingResult {
        // Encoding consumes the intermediate movie. The final GIF must remain on
        // disk for clipboard file promises, but retaining every H.264 recording
        // would leak tens of megabytes across experiment runs.
        defer {
            try? FileManager.default.removeItem(at: movie.info.movieURL)
        }
        let totalWallStart = ProcessInfo.processInfo.systemUptime
        let totalCPUStart = Self.processCPUTime()
        var attempts: [GIFEncodingAttempt] = []
        var previousAttemptURL: URL?

        do {
            for (index, policy) in policies.enumerated() {
                try Task.checkCancellation()
                let encodingTask = Task.detached(priority: .userInitiated) {
                    try Self.encodeAttempt(
                        movieURL: movie.info.movieURL,
                        sessionID: sessionID,
                        policy: policy,
                        trimRange: trimRange
                    )
                }
                let output = try await withTaskCancellationHandler(
                    operation: {
                        try await encodingTask.value
                    },
                    onCancel: {
                        encodingTask.cancel()
                    }
                )

                attempts.append(
                    GIFEncodingAttempt(
                        frameRate: policy.frameRate,
                        maxDimension: policy.maxDimension,
                        outputPixelSize: output.outputPixelSize,
                        gifBytes: output.bytes,
                        wallTime: output.wallTime,
                        cpuTime: output.cpuTime
                    )
                )

                if let previousAttemptURL {
                    try? FileManager.default.removeItem(at: previousAttemptURL)
                }
                previousAttemptURL = output.url

                let isLastPolicy = index == policies.count - 1
                guard output.bytes <= maximumBytes || isLastPolicy else {
                    continue
                }

                let data: Data
                do {
                    data = try Data(contentsOf: output.url, options: [.mappedIfSafe])
                } catch {
                    throw GIFMediaPipelineError.unableToReadGIF
                }
                let result = GIFEncodingResult(
                    sessionID: sessionID,
                    data: data,
                    fileURL: output.url,
                    outputPixelSize: output.outputPixelSize,
                    frameRate: policy.frameRate,
                    duration: output.duration,
                    gifBytes: output.bytes,
                    attempts: attempts,
                    encodingWallTime: ProcessInfo.processInfo.systemUptime - totalWallStart,
                    encodingCPUTime: max(0, Self.processCPUTime() - totalCPUStart),
                    exceedsMaximumBytes: output.bytes > maximumBytes
                )
                GIFExperimentLogger.recordEncoding(result, movie: movie)
                return result
            }

            throw GIFMediaPipelineError.unableToCreateGIF
        } catch is CancellationError {
            if let previousAttemptURL {
                try? FileManager.default.removeItem(at: previousAttemptURL)
            }
            throw CancellationError()
        } catch {
            if let previousAttemptURL {
                try? FileManager.default.removeItem(at: previousAttemptURL)
            }
            GIFExperimentLogger.recordError(
                sessionID: sessionID,
                stage: .encoding,
                error: error,
                region: movie.info.region,
                outputPixelSize: movie.info.outputPixelSize
            )
            throw error
        }
    }

    private static func encodeAttempt(
        movieURL: URL,
        sessionID: UUID,
        policy: Policy,
        trimRange: GIFTrimRange?
    ) throws -> AttemptOutput {
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = processCPUTime()
        let asset = AVURLAsset(url: movieURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0,
              !asset.tracks(withMediaType: .video).isEmpty else {
            throw GIFMediaPipelineError.unreadableMovie
        }
        guard let schedule = GIFFrameSchedule(
            trimRange: trimRange,
            assetDuration: seconds,
            frameRate: policy.frameRate
        ) else {
            throw GIFMediaPipelineError.invalidTrimRange
        }

        let frameCount = schedule.frameCount
        let outputURL = try GIFTemporaryFiles.makeURL(
            sessionID: sessionID,
            kind: "\(policy.frameRate)fps-\(policy.maxDimension)",
            pathExtension: "gif"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw GIFMediaPipelineError.unableToCreateGIF
        }

        let containerProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: CGFloat(policy.maxDimension),
            height: CGFloat(policy.maxDimension)
        )
        if trimRange == nil {
            // Preserve the faster whole-movie path used by the experimental
            // recorder before trimming was introduced.
            let tolerance = CMTime(
                value: 1,
                timescale: CMTimeScale(policy.frameRate * 2)
            )
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
        } else {
            // A non-zero tolerance can return a key frame before the trim start
            // or after its end. Exact tolerance keeps every sampled image inside
            // the user-selected half-open time range.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }

        var outputPixelSize = CGSize.zero
        do {
            for index in 0..<frameCount {
                if index % 10 == 0 {
                    try Task.checkCancellation()
                }
                guard let requestedSeconds = schedule.sampleTime(forFrame: index),
                      let frameDelay = schedule.frameDelay(forFrame: index),
                      frameDelay > 0 else {
                    throw GIFMediaPipelineError.invalidTrimRange
                }
                let requestedTime = CMTime(
                    seconds: requestedSeconds,
                    preferredTimescale: 600
                )
                var actualTime = CMTime.invalid
                let image = try generator.copyCGImage(
                    at: requestedTime,
                    actualTime: &actualTime
                )
                if outputPixelSize == .zero {
                    outputPixelSize = CGSize(
                        width: CGFloat(image.width),
                        height: CGFloat(image.height)
                    )
                }
                let frameProperties: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frameDelay,
                        kCGImagePropertyGIFUnclampedDelayTime: frameDelay
                    ]
                ]
                CGImageDestinationAddImage(
                    destination,
                    image,
                    frameProperties as CFDictionary
                )
            }

            guard CGImageDestinationFinalize(destination) else {
                throw GIFMediaPipelineError.unableToCreateGIF
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return AttemptOutput(
            url: outputURL,
            outputPixelSize: outputPixelSize,
            duration: schedule.range.duration,
            bytes: bytes,
            wallTime: ProcessInfo.processInfo.systemUptime - wallStart,
            cpuTime: max(0, processCPUTime() - cpuStart)
        )
    }

    private static func processCPUTime() -> TimeInterval {
        Double(clock()) / Double(CLOCKS_PER_SEC)
    }
}

// MARK: - Privacy-preserving experiment log

enum GIFExperimentLogger {
    private struct RectValue: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = Double(rect.origin.x)
            y = Double(rect.origin.y)
            width = Double(rect.width)
            height = Double(rect.height)
        }
    }

    private struct SizeValue: Encodable {
        let width: Int
        let height: Int

        init(_ size: CGSize) {
            width = Int(size.width)
            height = Int(size.height)
        }
    }

    private struct ErrorValue: Encodable {
        let kind: String
        let domain: String
        let code: Int

        init(_ error: Error) {
            let value = error as NSError
            kind = (error as? GIFMediaPipelineError)?.diagnosticKind ?? "system_error"
            domain = value.domain
            code = value.code
        }
    }

    private struct Event: Encodable {
        let timestamp: Date
        let sessionID: UUID
        let event: String
        let stage: GIFExperimentStage?
        let displayID: UInt32?
        let region: RectValue?
        let backingScaleFactor: Double?
        let output: SizeValue?
        let frames: GIFFrameStatistics?
        let durationSeconds: TimeInterval?
        let movieBytes: Int64?
        let gifBytes: Int64?
        let frameRate: Int?
        let encodingAttempts: [GIFEncodingAttempt]?
        let encodingWallSeconds: TimeInterval?
        let encodingCPUSeconds: TimeInterval?
        let exceedsMaximumBytes: Bool?
        let error: ErrorValue?
    }

    private static let lock = NSLock()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static var fileURL: URL {
        let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(
                "PocketIMGShot-GIF-Experiment.jsonl",
                isDirectory: false
            )
    }

    static func makeSessionID() -> UUID {
        GIFTemporaryFiles.removeExpiredFiles()
        return UUID()
    }

    static func recordSessionStarted(_ info: GIFRecordingInfo) {
        write(
            Event(
                timestamp: info.startedAt,
                sessionID: info.sessionID,
                event: "session_started",
                stage: .recording,
                displayID: info.region.displayID,
                region: RectValue(info.region.sourceRect),
                backingScaleFactor: Double(info.region.backingScaleFactor),
                output: SizeValue(info.outputPixelSize),
                frames: nil,
                durationSeconds: nil,
                movieBytes: nil,
                gifBytes: nil,
                frameRate: 10,
                encodingAttempts: nil,
                encodingWallSeconds: nil,
                encodingCPUSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    static func recordRecordingAttempt(
        sessionID: UUID,
        region: GIFCaptureRegion,
        outputPixelSize: CGSize
    ) {
        write(
            Event(
                timestamp: Date(),
                sessionID: sessionID,
                event: "recording_attempted",
                stage: .recordingSetup,
                displayID: region.displayID,
                region: RectValue(region.sourceRect),
                backingScaleFactor: Double(region.backingScaleFactor),
                output: SizeValue(outputPixelSize),
                frames: nil,
                durationSeconds: nil,
                movieBytes: nil,
                gifBytes: nil,
                frameRate: 10,
                encodingAttempts: nil,
                encodingWallSeconds: nil,
                encodingCPUSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    static func recordRecording(_ movie: GIFMovieRecording) {
        write(
            Event(
                timestamp: Date(),
                sessionID: movie.info.sessionID,
                event: "recording_finished",
                stage: .recordingStop,
                displayID: movie.info.region.displayID,
                region: RectValue(movie.info.region.sourceRect),
                backingScaleFactor: Double(movie.info.region.backingScaleFactor),
                output: SizeValue(movie.info.outputPixelSize),
                frames: movie.frames,
                durationSeconds: movie.duration,
                movieBytes: movie.movieBytes,
                gifBytes: nil,
                frameRate: 10,
                encodingAttempts: nil,
                encodingWallSeconds: nil,
                encodingCPUSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    static func recordEncoding(_ result: GIFEncodingResult, movie: GIFMovieRecording) {
        write(
            Event(
                timestamp: Date(),
                sessionID: result.sessionID,
                event: "encoding_finished",
                stage: .encoding,
                displayID: movie.info.region.displayID,
                region: RectValue(movie.info.region.sourceRect),
                backingScaleFactor: Double(movie.info.region.backingScaleFactor),
                output: SizeValue(result.outputPixelSize),
                frames: movie.frames,
                durationSeconds: result.duration,
                movieBytes: movie.movieBytes,
                gifBytes: result.gifBytes,
                frameRate: result.frameRate,
                encodingAttempts: result.attempts,
                encodingWallSeconds: result.encodingWallTime,
                encodingCPUSeconds: result.encodingCPUTime,
                exceedsMaximumBytes: result.exceedsMaximumBytes,
                error: nil
            )
        )
    }

    static func recordError(
        sessionID: UUID,
        stage: GIFExperimentStage,
        error: Error,
        region: GIFCaptureRegion? = nil,
        outputPixelSize: CGSize? = nil
    ) {
        write(
            Event(
                timestamp: Date(),
                sessionID: sessionID,
                event: "error",
                stage: stage,
                displayID: region?.displayID,
                region: region.map { RectValue($0.sourceRect) },
                backingScaleFactor: region.map { Double($0.backingScaleFactor) },
                output: outputPixelSize.map { SizeValue($0) },
                frames: nil,
                durationSeconds: nil,
                movieBytes: nil,
                gifBytes: nil,
                frameRate: nil,
                encodingAttempts: nil,
                encodingWallSeconds: nil,
                encodingCPUSeconds: nil,
                exceedsMaximumBytes: nil,
                error: ErrorValue(error)
            )
        )
    }

    static func recordOutcome(
        sessionID: UUID,
        stage: GIFExperimentStage,
        event: String
    ) {
        write(
            Event(
                timestamp: Date(),
                sessionID: sessionID,
                event: event,
                stage: stage,
                displayID: nil,
                region: nil,
                backingScaleFactor: nil,
                output: nil,
                frames: nil,
                durationSeconds: nil,
                movieBytes: nil,
                gifBytes: nil,
                frameRate: nil,
                encodingAttempts: nil,
                encodingWallSeconds: nil,
                encodingCPUSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    private static func write(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }

        do {
            var data = try encoder.encode(event)
            data.append(0x0A)
            let url = fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: [.atomic])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // The experiment log must never make recording or encoding fail.
        }
    }
}

private enum GIFTemporaryFiles {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PocketIMGShot-GIF", isDirectory: true)

    static func removeExpiredFiles(
        olderThan interval: TimeInterval = 7 * 24 * 60 * 60
    ) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let expirationDate = Date().addingTimeInterval(-interval)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modifiedAt = values?.contentModificationDate,
                  modifiedAt < expirationDate else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    static func makeURL(
        sessionID: UUID,
        kind: String,
        pathExtension: String
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw GIFMediaPipelineError.unableToCreateTemporaryDirectory
        }
        return directory
            .appendingPathComponent(
                "\(sessionID.uuidString)-\(kind)-\(UUID().uuidString)",
                isDirectory: false
            )
            .appendingPathExtension(pathExtension)
    }
}
