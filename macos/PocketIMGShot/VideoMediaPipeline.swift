import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - Values shared with the Video recording coordinator

/// A crop in the selected display's ScreenCaptureKit coordinate space.
/// `sourceRect` is expressed in display points, with the origin expected by
/// `SCStreamConfiguration.sourceRect`. `backingScaleFactor` converts those
/// points into source pixels before the 1280-pixel recording cap is applied.
struct VideoCaptureRegion: Sendable {
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

struct VideoFrameStatistics: Codable, Equatable, Sendable {
    let received: Int
    let appended: Int
    let dropped: Int
    let synthetic: Int
    let idle: Int
    let invalid: Int
    let backpressure: Int
    let appendFailed: Int
}

struct VideoRecordingInfo: Sendable {
    let sessionID: UUID
    let region: VideoCaptureRegion
    let outputPixelSize: CGSize
    let movieURL: URL
    let startedAt: Date
}

struct VideoMovieRecording: Sendable {
    let info: VideoRecordingInfo
    let duration: TimeInterval
    let movieBytes: Int64
    let frames: VideoFrameStatistics
}

/// A half-open time range used while exporting the intermediate movie.
///
/// Callers may construct a range before the movie's exact duration is known.
/// `normalized(forDuration:)` clamps both endpoints to the asset and rejects
/// ranges that are reversed, non-finite, or too short to produce a useful video.
struct VideoTrimRange: Equatable, Sendable {
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

    func normalized(forDuration assetDuration: TimeInterval) -> VideoTrimRange? {
        guard assetDuration.isFinite,
              assetDuration > 0,
              start.isFinite,
              end.isFinite,
              end > start else {
            return nil
        }
        let normalized = VideoTrimRange(
            start: min(max(0, start), assetDuration),
            end: min(max(0, end), assetDuration)
        )
        return normalized.isValid ? normalized : nil
    }
}

struct VideoExportResult: Sendable {
    let sessionID: UUID
    let data: Data
    let fileURL: URL
    let outputPixelSize: CGSize
    let duration: TimeInterval
    let videoBytes: Int64
    let exportWallTime: TimeInterval
    let exceedsMaximumBytes: Bool
}

enum VideoExperimentStage: String, Codable, Sendable {
    case selection
    case recordingSetup = "recording_setup"
    case recording
    case recordingStop = "recording_stop"
    case exporting
    case clipboard
    case upload
}

enum VideoMediaPipelineError: LocalizedError, Sendable {
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
    case unableToCreateVideoExporter
    case videoExportFailed(domain: String, code: Int)
    case unableToReadVideo

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            return "The selected video recording region is invalid."
        case .invalidTrimRange:
            return "The selected video time range is invalid or too short."
        case .displayNotFound:
            return "The selected display is no longer available."
        case .startInProgress:
            return "Video recording is still starting."
        case .alreadyRecording:
            return "A video recording is already active."
        case .notRecording:
            return "No video recording is active."
        case .unableToCreateTemporaryDirectory:
            return "The temporary video recording directory could not be created."
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
        case .unableToCreateVideoExporter:
            return "The video exporter could not be created."
        case .videoExportFailed:
            return "The selected video could not be exported."
        case .unableToReadVideo:
            return "The exported video could not be read."
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
        case .unableToCreateVideoExporter: return "video_exporter_create"
        case .videoExportFailed: return "video_export"
        case .unableToReadVideo: return "video_read"
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
        let info: VideoRecordingInfo
        let stream: SCStream
        let output: VideoStreamOutput

        init(info: VideoRecordingInfo, stream: SCStream, output: VideoStreamOutput) {
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

    func start(region: VideoCaptureRegion, sessionID: UUID) async throws -> VideoRecordingInfo {
        switch state {
        case .idle:
            break
        case .starting:
            throw VideoMediaPipelineError.startInProgress
        case .recording, .stopping:
            throw VideoMediaPipelineError.alreadyRecording
        }

        guard Self.isValid(region) else {
            VideoExperimentLogger.recordError(
                sessionID: sessionID,
                stage: .recordingSetup,
                error: VideoMediaPipelineError.invalidRegion
            )
            throw VideoMediaPipelineError.invalidRegion
        }

        state = .starting
        cancelStartRequested = false
        cancelStopRequested = false

        let outputSize = Self.outputPixelSize(for: region)
        VideoExperimentLogger.recordRecordingAttempt(
            sessionID: sessionID,
            region: region,
            outputPixelSize: outputSize
        )
        var createdOutput: VideoStreamOutput?
        var createdStream: SCStream?
        do {
            let movieURL = try VideoTemporaryFiles.makeURL(
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
                throw VideoMediaPipelineError.displayNotFound
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
            let info = VideoRecordingInfo(
                sessionID: sessionID,
                region: region,
                outputPixelSize: outputSize,
                movieURL: movieURL,
                startedAt: startedAt
            )
            let output = try VideoStreamOutput(
                movieURL: movieURL,
                outputPixelSize: outputSize,
                frameRate: 10,
                onUnexpectedStop: { [onUnexpectedStop] error in
                    VideoExperimentLogger.recordError(
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
            VideoExperimentLogger.recordSessionStarted(info)
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
                VideoExperimentLogger.recordError(
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

    func stop() async throws -> VideoMovieRecording {
        let active: ActiveRecording
        switch state {
        case .recording(let value):
            active = value
        case .starting:
            throw VideoMediaPipelineError.startInProgress
        case .idle, .stopping:
            throw VideoMediaPipelineError.notRecording
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

            let movie = VideoMovieRecording(
                info: active.info,
                duration: summary.duration,
                movieBytes: Self.fileSize(at: active.info.movieURL),
                frames: summary.frames
            )
            VideoExperimentLogger.recordRecording(movie)
            return movie
        } catch {
            state = .idle
            cancelStartRequested = false
            cancelStopRequested = false
            try? FileManager.default.removeItem(at: active.info.movieURL)
            if !(error is CancellationError) {
                VideoExperimentLogger.recordError(
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
            // the movie instead of handing it to the exporter.
            cancelStopRequested = true
        }
    }

    private func checkStartCancellation() throws {
        try Task.checkCancellation()
        if cancelStartRequested {
            throw CancellationError()
        }
    }

    private static func isValid(_ region: VideoCaptureRegion) -> Bool {
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

    private static func outputPixelSize(for region: VideoCaptureRegion) -> CGSize {
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

private final class VideoStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Summary: Sendable {
        let duration: TimeInterval
        let frames: VideoFrameStatistics
    }

    let sampleQueue = DispatchQueue(
        label: "com.gmch.pocketimg.shot.video-recording",
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
            throw VideoMediaPipelineError.unableToCreateAssetWriter
        }

        let width = Int(outputPixelSize.width)
        let height = Int(outputPixelSize.height)
        // Screen recordings contain large flat areas and run at only 10 fps.
        // This cap keeps a 30-second clip comfortably below the server's
        // 25 MiB upload limit without making text unreadable.
        let bitsPerPixel = 2.5
        let estimatedBitRate = max(
            600_000,
            min(4_000_000, Int(Double(width * height) * bitsPerPixel))
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: estimatedBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
            ]
        ]
        writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = true

        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video),
              writer.canAdd(writerInput) else {
            throw VideoMediaPipelineError.unableToConfigureAssetWriter
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw VideoMediaPipelineError.unableToStartAssetWriter
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
                    continuation.resume(throwing: VideoMediaPipelineError.notRecording)
                    return
                }
                finalized = true

                guard appendedFrames > 0,
                      let firstPresentationTime,
                      let lastPresentationTime else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: movieURL)
                    continuation.resume(throwing: VideoMediaPipelineError.noVideoFrames)
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
                                frames: VideoFrameStatistics(
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
        return VideoMediaPipelineError.screenCaptureStopped(
            domain: value.domain,
            code: value.code
        )
    }

    private static func pipelineError(forWriterError error: Error?) -> Error {
        let value = error as NSError?
        return VideoMediaPipelineError.assetWriterFailed(
            domain: value?.domain ?? AVFoundationErrorDomain,
            code: value?.code ?? -1
        )
    }
}

// MARK: - Trimmed, network-optimized H.264 MP4

actor VideoExporter {
    private let maximumBytes: Int64

    init(maximumBytes: Int64 = 24 * 1024 * 1024) {
        self.maximumBytes = maximumBytes
    }

    func export(
        movie: VideoMovieRecording,
        sessionID: UUID,
        trimRange: VideoTrimRange? = nil
    ) async throws -> VideoExportResult {
        defer {
            try? FileManager.default.removeItem(at: movie.info.movieURL)
        }

        try Task.checkCancellation()
        let wallStart = ProcessInfo.processInfo.systemUptime
        let asset = AVURLAsset(url: movie.info.movieURL)
        let assetDuration = CMTimeGetSeconds(asset.duration)
        guard assetDuration.isFinite,
              assetDuration > 0,
              !asset.tracks(withMediaType: .video).isEmpty else {
            throw VideoMediaPipelineError.unreadableMovie
        }
        guard let range = (trimRange ?? VideoTrimRange(start: 0, end: assetDuration))
            .normalized(forDuration: assetDuration) else {
            throw VideoMediaPipelineError.invalidTrimRange
        }

        let outputURL = try VideoTemporaryFiles.makeURL(
            sessionID: sessionID,
            kind: "clip",
            pathExtension: "mp4"
        )
        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ), exporter.supportedFileTypes.contains(.mp4) else {
            throw VideoMediaPipelineError.unableToCreateVideoExporter
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            duration: CMTime(seconds: range.duration, preferredTimescale: 600)
        )

        do {
            try Task.checkCancellation()
            try await Self.run(exporter)
            try Task.checkCancellation()
            let data: Data
            do {
                // The upload action removes the temporary file before the async
                // request starts. Keep an owned copy so that upload/retry never
                // relies on the lifetime of a file-backed mapping.
                data = try Data(contentsOf: outputURL)
            } catch {
                throw VideoMediaPipelineError.unableToReadVideo
            }
            guard !data.isEmpty else {
                throw VideoMediaPipelineError.unableToReadVideo
            }
            try Task.checkCancellation()
            let result = VideoExportResult(
                sessionID: sessionID,
                data: data,
                fileURL: outputURL,
                outputPixelSize: movie.info.outputPixelSize,
                duration: range.duration,
                videoBytes: Int64(data.count),
                exportWallTime: ProcessInfo.processInfo.systemUptime - wallStart,
                exceedsMaximumBytes: Int64(data.count) > maximumBytes
            )
            VideoExperimentLogger.recordExport(result, movie: movie)
            return result
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            VideoExperimentLogger.recordError(
                sessionID: sessionID,
                stage: .exporting,
                error: error,
                region: movie.info.region,
                outputPixelSize: movie.info.outputPixelSize
            )
            throw error
        }
    }

    private static func run(_ exporter: AVAssetExportSession) async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    exporter.exportAsynchronously {
                        switch exporter.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        default:
                            let value = exporter.error as NSError?
                            continuation.resume(throwing: VideoMediaPipelineError.videoExportFailed(
                                domain: value?.domain ?? AVFoundationErrorDomain,
                                code: value?.code ?? -1
                            ))
                        }
                    }
                }
            },
            onCancel: {
                exporter.cancelExport()
            }
        )
    }
}

// MARK: - Privacy-preserving experiment log

enum VideoExperimentLogger {
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
            kind = (error as? VideoMediaPipelineError)?.diagnosticKind ?? "system_error"
            domain = value.domain
            code = value.code
        }
    }

    private struct Event: Encodable {
        let timestamp: Date
        let sessionID: UUID
        let event: String
        let stage: VideoExperimentStage?
        let displayID: UInt32?
        let region: RectValue?
        let backingScaleFactor: Double?
        let output: SizeValue?
        let frames: VideoFrameStatistics?
        let durationSeconds: TimeInterval?
        let movieBytes: Int64?
        let videoBytes: Int64?
        let frameRate: Int?
        let exportWallSeconds: TimeInterval?
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
                "PocketIMGShot-Video-Experiment.jsonl",
                isDirectory: false
            )
    }

    static func makeSessionID() -> UUID {
        VideoTemporaryFiles.removeExpiredFiles()
        return UUID()
    }

    static func recordSessionStarted(_ info: VideoRecordingInfo) {
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
                videoBytes: nil,
                frameRate: 10,
                exportWallSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    static func recordRecordingAttempt(
        sessionID: UUID,
        region: VideoCaptureRegion,
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
                videoBytes: nil,
                frameRate: 10,
                exportWallSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    static func recordRecording(_ movie: VideoMovieRecording) {
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
                videoBytes: nil,
                frameRate: 10,
                exportWallSeconds: nil,
                exceedsMaximumBytes: nil,
                error: nil
            )
        )
    }

    static func recordExport(_ result: VideoExportResult, movie: VideoMovieRecording) {
        write(
            Event(
                timestamp: Date(),
                sessionID: result.sessionID,
                event: "export_finished",
                stage: .exporting,
                displayID: movie.info.region.displayID,
                region: RectValue(movie.info.region.sourceRect),
                backingScaleFactor: Double(movie.info.region.backingScaleFactor),
                output: SizeValue(result.outputPixelSize),
                frames: movie.frames,
                durationSeconds: result.duration,
                movieBytes: movie.movieBytes,
                videoBytes: result.videoBytes,
                frameRate: 10,
                exportWallSeconds: result.exportWallTime,
                exceedsMaximumBytes: result.exceedsMaximumBytes,
                error: nil
            )
        )
    }

    static func recordError(
        sessionID: UUID,
        stage: VideoExperimentStage,
        error: Error,
        region: VideoCaptureRegion? = nil,
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
                videoBytes: nil,
                frameRate: nil,
                exportWallSeconds: nil,
                exceedsMaximumBytes: nil,
                error: ErrorValue(error)
            )
        )
    }

    static func recordOutcome(
        sessionID: UUID,
        stage: VideoExperimentStage,
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
                videoBytes: nil,
                frameRate: nil,
                exportWallSeconds: nil,
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
            // Diagnostics must never make recording or exporting fail.
        }
    }
}

private enum VideoTemporaryFiles {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PocketIMGShot-Video", isDirectory: true)

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
            throw VideoMediaPipelineError.unableToCreateTemporaryDirectory
        }
        return directory
            .appendingPathComponent(
                "\(sessionID.uuidString)-\(kind)-\(UUID().uuidString)",
                isDirectory: false
            )
            .appendingPathExtension(pathExtension)
    }
}
