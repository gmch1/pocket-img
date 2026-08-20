import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import QuartzCore

enum GIFTrimHandle: Equatable {
    case start
    case end
}

enum GIFTrimGeometry {
    static func x(
        forTime time: TimeInterval,
        duration: TimeInterval,
        trackRect: CGRect
    ) -> CGFloat {
        guard time.isFinite,
              duration.isFinite,
              duration > 0,
              trackRect.width > 0 else {
            return trackRect.minX
        }
        let progress = min(1, max(0, time / duration))
        return trackRect.minX + trackRect.width * CGFloat(progress)
    }

    static func time(
        forX x: CGFloat,
        duration: TimeInterval,
        trackRect: CGRect
    ) -> TimeInterval {
        guard x.isFinite,
              duration.isFinite,
              duration > 0,
              trackRect.width > 0 else {
            return 0
        }
        let progress = min(1, max(0, (x - trackRect.minX) / trackRect.width))
        return Double(progress) * duration
    }

    static func clampedRange(
        current: GIFTrimRange,
        changing handle: GIFTrimHandle,
        proposedTime: TimeInterval,
        duration: TimeInterval,
        minimumDuration: TimeInterval,
        snap: TimeInterval
    ) -> GIFTrimRange {
        guard proposedTime.isFinite,
              duration.isFinite,
              duration > 0 else {
            return current
        }
        let safeMinimum = min(duration, max(0, minimumDuration))
        let snapped: TimeInterval
        if snap.isFinite, snap > 0 {
            snapped = (proposedTime / snap).rounded() * snap
        } else {
            snapped = proposedTime
        }

        switch handle {
        case .start:
            let latest = max(0, current.end - safeMinimum)
            return GIFTrimRange(
                start: min(latest, max(0, snapped)),
                end: current.end
            )
        case .end:
            let earliest = min(duration, current.start + safeMinimum)
            return GIFTrimRange(
                start: current.start,
                end: max(earliest, min(duration, snapped))
            )
        }
    }
}

@MainActor
final class GIFTrimEditorController: NSObject, NSWindowDelegate {
    private let movieURL: URL
    private let duration: TimeInterval
    private let frameRate: Int
    private let language: AppLanguage
    private var onConfirm: ((GIFTrimRange) -> Void)?
    private var onCancel: (() -> Void)?

    private let player: AVPlayer
    private let playerView: GIFTrimPlayerView
    private let timeline: GIFTrimTimelineView
    private let playButton = NSButton()
    private let currentTimeLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private var editorWindow: NSWindow?
    private var timeObserver: Any?
    private var keyMonitor: Any?
    private var thumbnailTask: Task<Void, Never>?
    private var resolved = false

    init(
        movieURL: URL,
        duration: TimeInterval,
        frameRate: Int,
        pixelSize: CGSize,
        language: AppLanguage,
        onConfirm: @escaping (GIFTrimRange) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let safeDuration = duration.isFinite
            ? max(GIFTrimRange.minimumDuration, duration)
            : GIFTrimRange.minimumDuration
        let safeFrameRate = max(1, frameRate)
        let player = AVPlayer(url: movieURL)
        self.movieURL = movieURL
        self.duration = safeDuration
        self.frameRate = safeFrameRate
        self.language = language
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.player = player
        playerView = GIFTrimPlayerView(player: player)
        timeline = GIFTrimTimelineView(
            duration: safeDuration,
            frameRate: safeFrameRate,
            language: language
        )
        super.init()
        configureWindow(pixelSize: pixelSize)
        configurePlayback()
    }

    func show() {
        guard !resolved, let editorWindow else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        editorWindow.center()
        editorWindow.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        startThumbnailGeneration()
        seek(to: timeline.trimRange.start, exact: true)
        updateSelectionLabels()
    }

    func dismiss(notify: Bool) {
        guard !resolved else {
            teardown()
            return
        }
        resolved = true
        let cancellation = notify ? onCancel : nil
        onConfirm = nil
        onCancel = nil
        teardown()
        closeWindow()
        cancellation?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !resolved else { return }
        resolved = true
        let cancellation = onCancel
        onConfirm = nil
        onCancel = nil
        teardown()
        editorWindow = nil
        cancellation?()
    }

    private func configureWindow(pixelSize: CGSize) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("gif.editor.title", language: language)
        window.minSize = CGSize(width: 650, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.sharingType = .none

        let root = NSView()
        window.contentView = root

        let instructions = NSTextField(
            labelWithString: L10n.text("gif.editor.instructions", language: language)
        )
        instructions.font = .systemFont(ofSize: 13)
        instructions.textColor = .secondaryLabelColor
        instructions.lineBreakMode = .byWordWrapping
        instructions.maximumNumberOfLines = 2

        let metadata = NSTextField(
            labelWithString: "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) · \(Self.timecode(duration))"
        )
        metadata.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metadata.textColor = .tertiaryLabelColor

        playButton.title = L10n.text("gif.editor.play", language: language)
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)

        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        currentTimeLabel.alignment = .right
        currentTimeLabel.stringValue = Self.timecode(0)

        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        selectionLabel.alignment = .center

        let generateButton = NSButton(
            title: L10n.text("gif.editor.generate", language: language),
            target: self,
            action: #selector(confirmTrim)
        )
        generateButton.bezelStyle = .rounded
        generateButton.keyEquivalent = "\r"

        let cancelButton = NSButton(
            title: L10n.text("gif.editor.cancel", language: language),
            target: self,
            action: #selector(cancelTrim)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let transport = NSStackView(views: [playButton, NSView(), currentTimeLabel])
        transport.orientation = .horizontal
        transport.alignment = .centerY
        transport.spacing = 10

        let actions = NSStackView(views: [NSView(), cancelButton, generateButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        for view in [
            instructions,
            metadata,
            playerView,
            transport,
            timeline,
            selectionLabel,
            actions,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            instructions.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            instructions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            instructions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            metadata.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 4),
            metadata.leadingAnchor.constraint(equalTo: instructions.leadingAnchor),

            playerView.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 12),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),

            transport.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 10),
            transport.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: 30),

            timeline.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 8),
            timeline.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 82),

            selectionLabel.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 6),
            selectionLabel.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            selectionLabel.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),

            actions.topAnchor.constraint(equalTo: selectionLabel.bottomAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            actions.heightAnchor.constraint(equalToConstant: 32),
        ])

        timeline.onRangeChange = { [weak self] range, handle in
            guard let self else { return }
            player.pause()
            updatePlayButton()
            player.currentItem?.forwardPlaybackEndTime = Self.mediaTime(range.end)
            let previewTime = handle == .start
                ? range.start
                : max(range.start, range.end - 1 / Double(frameRate))
            seek(to: previewTime, exact: true)
            updateSelectionLabels()
        }

        editorWindow = window
    }

    private func configurePlayback() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.currentItem?.forwardPlaybackEndTime = Self.mediaTime(timeline.trimRange.end)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !resolved else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                currentTimeLabel.stringValue = Self.timecode(seconds)
                timeline.playhead = min(
                    timeline.trimRange.end,
                    max(timeline.trimRange.start, seconds)
                )
                if seconds >= timeline.trimRange.end - 0.01 {
                    updatePlayButton()
                }
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      self.editorWindow?.isKeyWindow == true,
                      event.keyCode == UInt16(kVK_Space),
                      !event.isARepeat else {
                    return event
                }
                self.togglePlayback()
                return nil
            }
        }
    }

    private func startThumbnailGeneration() {
        thumbnailTask?.cancel()
        let url = movieURL
        let duration = duration
        thumbnailTask = Task { [weak self] in
            let images = await Self.loadThumbnails(
                movieURL: url,
                duration: duration,
                count: 10
            )
            guard !Task.isCancelled, let self, !resolved else { return }
            timeline.thumbnails = images
        }
    }

    private static func loadThumbnails(
        movieURL: URL,
        duration: TimeInterval,
        count: Int
    ) async -> [CGImage] {
        let worker = Task.detached(priority: .utility) { () throws -> [CGImage] in
            let asset = AVURLAsset(url: movieURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 100)
            let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            var images: [CGImage] = []
            for index in 0..<max(1, count) {
                try Task.checkCancellation()
                let progress = count <= 1 ? 0 : Double(index) / Double(count - 1)
                let seconds = min(max(0, duration - 0.001), duration * progress)
                var actualTime = CMTime.invalid
                if let image = try? generator.copyCGImage(
                    at: CMTime(seconds: seconds, preferredTimescale: 600),
                    actualTime: &actualTime
                ) {
                    images.append(image)
                }
            }
            return images
        }
        return await withTaskCancellationHandler(
            operation: { (try? await worker.value) ?? [] },
            onCancel: { worker.cancel() }
        )
    }

    @objc private func togglePlayback() {
        guard !resolved else { return }
        if player.rate > 0 {
            player.pause()
            updatePlayButton()
            return
        }
        let current = CMTimeGetSeconds(player.currentTime())
        if !current.isFinite
            || current < timeline.trimRange.start
            || current >= timeline.trimRange.end - 0.01 {
            seek(to: timeline.trimRange.start, exact: true) { [weak self] in
                self?.player.play()
                self?.updatePlayButton()
            }
        } else {
            player.play()
            updatePlayButton()
        }
    }

    private func seek(
        to seconds: TimeInterval,
        exact: Bool,
        completion: (() -> Void)? = nil
    ) {
        player.currentItem?.cancelPendingSeeks()
        let time = Self.mediaTime(min(duration, max(0, seconds)))
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 20)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            guard finished, let completion else { return }
            DispatchQueue.main.async(execute: completion)
        }
        currentTimeLabel.stringValue = Self.timecode(seconds)
        timeline.playhead = seconds
    }

    private func updateSelectionLabels() {
        let range = timeline.trimRange
        selectionLabel.stringValue = L10n.format(
            "gif.editor.selection",
            language: language,
            Self.timecode(range.start),
            Self.timecode(range.end),
            Self.timecode(range.duration)
        )
    }

    private func updatePlayButton() {
        playButton.title = L10n.text(
            player.rate > 0 ? "gif.editor.pause" : "gif.editor.play",
            language: language
        )
    }

    @objc private func confirmTrim() {
        guard !resolved,
              let normalized = timeline.trimRange.normalized(forDuration: duration) else {
            return
        }
        resolved = true
        let confirmation = onConfirm
        onConfirm = nil
        onCancel = nil
        teardown()
        closeWindow()
        confirmation?(normalized)
    }

    @objc private func cancelTrim() {
        dismiss(notify: true)
    }

    private func teardown() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        playerView.detachPlayer()
    }

    private func closeWindow() {
        let window = editorWindow
        editorWindow = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
    }

    private static func mediaTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safe) / 60
        let remainder = safe - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}

@MainActor
private final class GIFTrimPlayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func detachPlayer() {
        playerLayer.player = nil
    }
}

@MainActor
final class GIFTrimTimelineView: NSView {
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 8
    private static let handleWidth: CGFloat = 18

    let duration: TimeInterval
    let frameRate: Int
    private let language: AppLanguage
    private let minimumDuration: TimeInterval
    private let snap: TimeInterval
    private let startHandle: GIFTrimHandleControl
    private let endHandle: GIFTrimHandleControl
    private var trackingHandle: GIFTrimHandle?
    var onRangeChange: ((GIFTrimRange, GIFTrimHandle) -> Void)?

    var trimRange: GIFTrimRange {
        didSet {
            needsLayout = true
            needsDisplay = true
            updateHandleAccessibility()
        }
    }
    var thumbnails: [CGImage] = [] {
        didSet { needsDisplay = true }
    }
    var playhead: TimeInterval = 0 {
        didSet { needsDisplay = true }
    }

    init(duration: TimeInterval, frameRate: Int, language: AppLanguage) {
        self.duration = duration
        self.frameRate = max(1, frameRate)
        self.language = language
        minimumDuration = min(duration, max(GIFTrimRange.minimumDuration, 0.2))
        snap = 0.1
        trimRange = GIFTrimRange(start: 0, end: duration)
        startHandle = GIFTrimHandleControl(handle: .start)
        endHandle = GIFTrimHandleControl(handle: .end)
        super.init(frame: .zero)
        wantsLayer = true
        startHandle.owner = self
        endHandle.owner = self
        addSubview(startHandle)
        addSubview(endHandle)
        setAccessibilityElement(false)
        updateHandleAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    private var trackRect: CGRect {
        bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
    }

    override func layout() {
        super.layout()
        let rect = trackRect
        let startX = GIFTrimGeometry.x(
            forTime: trimRange.start,
            duration: duration,
            trackRect: rect
        )
        let endX = GIFTrimGeometry.x(
            forTime: trimRange.end,
            duration: duration,
            trackRect: rect
        )
        startHandle.frame = CGRect(
            x: startX - Self.handleWidth / 2,
            y: 0,
            width: Self.handleWidth,
            height: bounds.height
        )
        endHandle.frame = CGRect(
            x: endX - Self.handleWidth / 2,
            y: 0,
            width: Self.handleWidth,
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = trackRect
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        if !thumbnails.isEmpty {
            let slotWidth = rect.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                let slot = CGRect(
                    x: rect.minX + CGFloat(index) * slotWidth,
                    y: rect.minY,
                    width: slotWidth + 0.5,
                    height: rect.height
                )
                let thumbnail = NSImage(
                    cgImage: image,
                    size: CGSize(width: image.width, height: image.height)
                )
                thumbnail.draw(
                    in: slot,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.medium]
                )
            }
        }

        let startX = GIFTrimGeometry.x(
            forTime: trimRange.start,
            duration: duration,
            trackRect: rect
        )
        let endX = GIFTrimGeometry.x(
            forTime: trimRange.end,
            duration: duration,
            trackRect: rect
        )
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(rect: CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, startX - rect.minX),
            height: rect.height
        )).fill()
        NSBezierPath(rect: CGRect(
            x: endX,
            y: rect.minY,
            width: max(0, rect.maxX - endX),
            height: rect.height
        )).fill()

        NSColor.controlAccentColor.setStroke()
        let selected = CGRect(
            x: startX,
            y: rect.minY,
            width: max(0, endX - startX),
            height: rect.height
        )
        let selectionPath = NSBezierPath(roundedRect: selected, xRadius: 4, yRadius: 4)
        selectionPath.lineWidth = 2
        selectionPath.stroke()

        let playheadX = GIFTrimGeometry.x(
            forTime: playhead,
            duration: duration,
            trackRect: rect
        )
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let playheadPath = NSBezierPath()
        playheadPath.move(to: CGPoint(x: playheadX, y: rect.minY))
        playheadPath.line(to: CGPoint(x: playheadX, y: rect.maxY))
        playheadPath.lineWidth = 1
        playheadPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let startDistance = abs(point.x - startHandle.frame.midX)
        let endDistance = abs(point.x - endHandle.frame.midX)
        let handle: GIFTrimHandle = startDistance <= endDistance ? .start : .end
        trackingHandle = handle
        window?.makeFirstResponder(handle == .start ? startHandle : endHandle)
        update(handle: handle, using: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let trackingHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        update(handle: trackingHandle, using: point.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard let trackingHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        update(handle: trackingHandle, using: point.x)
        self.trackingHandle = nil
    }

    fileprivate func update(handle: GIFTrimHandle, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        update(handle: handle, using: point.x)
    }

    fileprivate func step(handle: GIFTrimHandle, by amount: TimeInterval) {
        let current = handle == .start ? trimRange.start : trimRange.end
        set(handle: handle, proposedTime: current + amount)
    }

    fileprivate func moveToBoundary(handle: GIFTrimHandle, end: Bool) {
        let proposed: TimeInterval
        switch (handle, end) {
        case (.start, false): proposed = 0
        case (.start, true): proposed = trimRange.end - minimumDuration
        case (.end, false): proposed = trimRange.start + minimumDuration
        case (.end, true): proposed = duration
        }
        set(handle: handle, proposedTime: proposed)
    }

    private func update(handle: GIFTrimHandle, using x: CGFloat) {
        let proposed = GIFTrimGeometry.time(forX: x, duration: duration, trackRect: trackRect)
        set(handle: handle, proposedTime: proposed)
    }

    private func set(handle: GIFTrimHandle, proposedTime: TimeInterval) {
        let updated = GIFTrimGeometry.clampedRange(
            current: trimRange,
            changing: handle,
            proposedTime: proposedTime,
            duration: duration,
            minimumDuration: minimumDuration,
            snap: snap
        )
        guard updated != trimRange else { return }
        trimRange = updated
        onRangeChange?(updated, handle)
        NSAccessibility.post(
            element: handle == .start ? startHandle : endHandle,
            notification: .valueChanged
        )
    }

    private func updateHandleAccessibility() {
        startHandle.configureAccessibility(
            label: L10n.text("gif.editor.start_handle", language: language),
            value: trimRange.start,
            maximum: max(0, trimRange.end - minimumDuration)
        )
        endHandle.configureAccessibility(
            label: L10n.text("gif.editor.end_handle", language: language),
            value: trimRange.end,
            minimum: min(duration, trimRange.start + minimumDuration),
            maximum: duration
        )
    }
}

@MainActor
private final class GIFTrimHandleControl: NSControl {
    let handle: GIFTrimHandle
    weak var owner: GIFTrimTimelineView?

    init(handle: GIFTrimHandle) {
        self.handle = handle
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 3, dy: 10)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let grip = NSBezierPath()
        grip.move(to: CGPoint(x: bounds.midX, y: body.minY + 8))
        grip.line(to: CGPoint(x: bounds.midX, y: body.maxY - 8))
        grip.lineWidth = 1.5
        grip.stroke()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: body.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        owner?.update(handle: handle, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.update(handle: handle, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.update(handle: handle, event: event)
    }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
        switch event.keyCode {
        case UInt16(kVK_LeftArrow):
            owner?.step(handle: handle, by: -step)
        case UInt16(kVK_RightArrow):
            owner?.step(handle: handle, by: step)
        case UInt16(kVK_Home):
            owner?.moveToBoundary(handle: handle, end: false)
        case UInt16(kVK_End):
            owner?.moveToBoundary(handle: handle, end: true)
        default:
            super.keyDown(with: event)
        }
    }

    func configureAccessibility(
        label: String,
        value: TimeInterval,
        minimum: TimeInterval = 0,
        maximum: TimeInterval
    ) {
        setAccessibilityLabel(label)
        setAccessibilityMinValue(NSNumber(value: minimum))
        setAccessibilityMaxValue(NSNumber(value: maximum))
        setAccessibilityValue(NSNumber(value: value))
        setAccessibilityValueDescription(GIFTrimEditorControllerTimecode.value(value))
    }
}

private enum GIFTrimEditorControllerTimecode {
    static func value(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safe) / 60
        let remainder = safe - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}
