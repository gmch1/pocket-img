import AppKit
import CoreGraphics

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidStartSelection(_ overlay: CaptureOverlayView)
    func captureOverlayDidCancel(_ overlay: CaptureOverlayView)
    func captureOverlay(_ overlay: CaptureOverlayView, didFinish payload: UploadPayload)
    func captureOverlay(_ overlay: CaptureOverlayView, didFailWith error: Error)
}

@MainActor
final class CaptureOverlayView: NSView {
    private enum Appearance {
        static let toolbarButtonSize: CGFloat = 38
        static let toolbarPadding: CGFloat = 6
        static let toolbarSpacing: CGFloat = 4
        static let toolbarGroupGap: CGFloat = 8
        static let toolbarCornerRadius: CGFloat = 12
    }

    weak var delegate: CaptureOverlayViewDelegate?
    var screenshot: CGImage? {
        didSet { needsDisplay = true }
    }

    private enum Mode {
        case selecting
        case editing
    }

    private enum ToolbarAction: CaseIterable {
        case rectangle
        case arrow
        case undo
        case cancel
        case upload

    }

    private var mode: Mode = .selecting
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var selectedTool: AnnotationTool = .rectangle
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var isFinishing = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .selecting ? .crosshair : .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))

        switch mode {
        case .selecting:
            delegate?.captureOverlayDidStartSelection(self)
            dragStart = point
            selection = CGRect(origin: point, size: .zero)
        case .editing:
            if let action = toolbarAction(at: point) {
                perform(action)
                return
            }
            guard selection?.contains(point) == true else { return }
            dragStart = point
            currentAnnotation = Annotation(tool: selectedTool, start: point, end: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFinishing, let dragStart else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        switch mode {
        case .selecting:
            selection = CGRect.between(dragStart, point).intersection(bounds)
        case .editing:
            guard let selection else { return }
            let endpoint = CGPoint(
                x: min(max(point.x, selection.minX), selection.maxX),
                y: min(max(point.y, selection.minY), selection.maxY)
            )
            currentAnnotation = Annotation(tool: selectedTool, start: dragStart, end: endpoint)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !isFinishing else { return }

        switch mode {
        case .selecting:
            guard let selection, selection.width >= 8, selection.height >= 8 else {
                self.selection = nil
                needsDisplay = true
                return
            }
            self.selection = selection.integral.intersection(bounds)
            mode = .editing
            window?.invalidateCursorRects(for: self)
        case .editing:
            if let annotation = currentAnnotation, annotation.isMeaningful {
                annotations.append(annotation)
            }
            currentAnnotation = nil
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.captureOverlayDidCancel(self)
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if !annotations.isEmpty { annotations.removeLast() }
            currentAnnotation = nil
            needsDisplay = true
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            finishAndUpload()
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": selectedTool = .rectangle
        case "a": selectedTool = .arrow
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let screenshot else {
            NSColor.black.setFill()
            NSBezierPath(rect: bounds).fill()
            return
        }

        let image = NSImage(cgImage: screenshot, size: bounds.size)
        let graphicsContext = NSGraphicsContext.current
        let previousInterpolation = graphicsContext?.imageInterpolation
        graphicsContext?.imageInterpolation = .none
        image.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        if let previousInterpolation {
            graphicsContext?.imageInterpolation = previousInterpolation
        }

        NSColor.black.withAlphaComponent(0.42).setFill()
        if let selection {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(selection)
            shade.windingRule = .evenOdd
            shade.fill()
            drawSelection(selection)
        } else {
            NSBezierPath(rect: bounds).fill()
            drawCenteredHint("拖拽选择截图区域  ·  Esc 取消")
        }
    }

    private func drawSelection(_ selection: CGRect) {
        let outline = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        NSColor.black.withAlphaComponent(0.65).setStroke()
        outline.lineWidth = 3
        outline.stroke()

        let accent = NSBezierPath(rect: selection.insetBy(dx: 0.25, dy: 0.25))
        NSColor.controlAccentColor.setStroke()
        accent.lineWidth = 1.5
        accent.stroke()

        for annotation in annotations {
            draw(annotation, color: .systemRed)
        }
        if let currentAnnotation {
            draw(currentAnnotation, color: .systemRed)
        }

        drawSizeLabel(selection)
        if mode == .editing { drawToolbar() }
    }

    private func draw(_ annotation: Annotation, color: NSColor) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.tool {
        case .rectangle:
            path.appendRect(annotation.rect)
        case .arrow:
            appendArrow(to: path, from: annotation.start, to: annotation.end, headLength: 14)
        }

        NSColor.black.withAlphaComponent(0.38).setStroke()
        path.lineWidth = 5
        path.stroke()
        color.setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    private func drawToolbar() {
        let frame = toolbarFrame()
        let background = NSBezierPath(
            roundedRect: frame,
            xRadius: Appearance.toolbarCornerRadius,
            yRadius: Appearance.toolbarCornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        background.lineWidth = 1
        background.stroke()

        let separatorX = toolbarButtonFrame(index: 2).maxX
            + Appearance.toolbarSpacing
            + Appearance.toolbarGroupGap / 2
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: separatorX, y: frame.minY + 11))
        separator.line(to: CGPoint(x: separatorX, y: frame.maxY - 11))
        NSColor.white.withAlphaComponent(0.14).setStroke()
        separator.lineWidth = 1
        separator.stroke()

        for (index, action) in ToolbarAction.allCases.enumerated() {
            let button = toolbarButtonFrame(index: index)
            let selected = (action == .rectangle && selectedTool == .rectangle)
                || (action == .arrow && selectedTool == .arrow)
            if action == .upload {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            } else if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            } else if action == .cancel {
                NSColor.systemRed.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            }
            let color: NSColor
            if action == .undo, annotations.isEmpty {
                color = NSColor.white.withAlphaComponent(0.3)
            } else if action == .cancel {
                color = NSColor.systemRed.withAlphaComponent(0.9)
            } else {
                color = action == .upload || selected
                    ? .white
                    : NSColor.white.withAlphaComponent(0.72)
            }
            drawToolbarIcon(action, in: button, color: color)
        }
    }

    private func drawToolbarIcon(_ action: ToolbarAction, in button: CGRect, color: NSColor) {
        let icon = CGRect(x: button.midX - 9, y: button.midY - 9, width: 18, height: 18)
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()

        switch action {
        case .rectangle:
            path.appendRoundedRect(icon.insetBy(dx: 1.5, dy: 2.5), xRadius: 1.5, yRadius: 1.5)
        case .arrow:
            let start = CGPoint(x: icon.minX + 2, y: icon.maxY - 2)
            let end = CGPoint(x: icon.maxX - 2, y: icon.minY + 2)
            path.move(to: start)
            path.line(to: end)
            path.move(to: CGPoint(x: end.x - 7, y: end.y))
            path.line(to: end)
            path.line(to: CGPoint(x: end.x, y: end.y + 7))
        case .undo:
            path.move(to: CGPoint(x: icon.minX + 3, y: icon.midY - 1))
            path.curve(
                to: CGPoint(x: icon.maxX - 2, y: icon.maxY - 3),
                controlPoint1: CGPoint(x: icon.midX + 2, y: icon.minY),
                controlPoint2: CGPoint(x: icon.maxX - 1, y: icon.midY + 1)
            )
            path.move(to: CGPoint(x: icon.minX + 3, y: icon.midY - 1))
            path.line(to: CGPoint(x: icon.minX + 7, y: icon.minY + 2))
            path.move(to: CGPoint(x: icon.minX + 3, y: icon.midY - 1))
            path.line(to: CGPoint(x: icon.minX + 8, y: icon.midY + 2))
        case .cancel:
            path.move(to: CGPoint(x: icon.minX + 3, y: icon.minY + 3))
            path.line(to: CGPoint(x: icon.maxX - 3, y: icon.maxY - 3))
            path.move(to: CGPoint(x: icon.maxX - 3, y: icon.minY + 3))
            path.line(to: CGPoint(x: icon.minX + 3, y: icon.maxY - 3))
        case .upload:
            path.move(to: CGPoint(x: icon.minX + 2, y: icon.maxY - 6))
            path.line(to: CGPoint(x: icon.minX + 2, y: icon.maxY - 2))
            path.line(to: CGPoint(x: icon.maxX - 2, y: icon.maxY - 2))
            path.line(to: CGPoint(x: icon.maxX - 2, y: icon.maxY - 6))
            path.move(to: CGPoint(x: icon.midX, y: icon.maxY - 5))
            path.line(to: CGPoint(x: icon.midX, y: icon.minY + 4))
            path.move(to: CGPoint(x: icon.midX - 4, y: icon.minY + 8))
            path.line(to: CGPoint(x: icon.midX, y: icon.minY + 4))
            path.line(to: CGPoint(x: icon.midX + 4, y: icon.minY + 8))
        }
        path.stroke()
    }

    private func drawSizeLabel(_ selection: CGRect) {
        guard selection.width >= 50 else { return }
        let scaleX = screenshot.map { CGFloat($0.width) / bounds.width } ?? 1
        let scaleY = screenshot.map { CGFloat($0.height) / bounds.height } ?? 1
        let value = "\(Int((selection.width * scaleX).rounded())) × \(Int((selection.height * scaleY).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = value.size(withAttributes: attributes)
        let labelSize = NSSize(width: textSize.width + 16, height: textSize.height + 8)
        let x = min(
            max(selection.minX, bounds.minX + 8),
            bounds.maxX - labelSize.width - 8
        )
        let above = selection.minY - labelSize.height - 7
        let y = above >= bounds.minY + 8 ? above : selection.minY + 7
        let labelFrame = NSRect(origin: NSPoint(x: x, y: y), size: labelSize)

        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: labelFrame, xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        NSBezierPath(roundedRect: labelFrame, xRadius: 6, yRadius: 6).stroke()
        value.draw(
            at: NSPoint(x: labelFrame.minX + 8, y: labelFrame.minY + 4),
            withAttributes: attributes
        )
    }

    private func drawCenteredHint(_ value: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = value.size(withAttributes: attributes)
        let background = NSRect(
            x: bounds.midX - size.width / 2 - 14,
            y: bounds.midY - size.height / 2 - 9,
            width: size.width + 28,
            height: size.height + 18
        )
        NSColor(calibratedWhite: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10).stroke()
        value.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func toolbarAction(at point: CGPoint) -> ToolbarAction? {
        guard toolbarFrame().contains(point) else { return nil }
        for (index, action) in ToolbarAction.allCases.enumerated()
            where toolbarButtonFrame(index: index).contains(point) {
            return action
        }
        return nil
    }

    private func perform(_ action: ToolbarAction) {
        switch action {
        case .rectangle:
            selectedTool = .rectangle
        case .arrow:
            selectedTool = .arrow
        case .undo:
            if !annotations.isEmpty { annotations.removeLast() }
            currentAnnotation = nil
        case .cancel:
            delegate?.captureOverlayDidCancel(self)
        case .upload:
            finishAndUpload()
        }
        needsDisplay = true
    }

    private func finishAndUpload() {
        guard mode == .editing, !isFinishing else { return }
        guard let screenshot, let selection else {
            delegate?.captureOverlay(self, didFailWith: CaptureError.imageEncodingFailed)
            return
        }
        isFinishing = true
        let viewBounds = bounds
        let annotations = annotations
        DiagnosticLog.record(
            "render started selection=\(Int(selection.width))x\(Int(selection.height)) " +
            "source=\(screenshot.width)x\(screenshot.height)"
        )

        Task { [weak self] in
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotRenderer.render(
                        screenshot: screenshot,
                        viewBounds: viewBounds,
                        selection: selection,
                        annotations: annotations
                    )
                }.value
                DiagnosticLog.record("render finished bytes=\(payload.data.count)")
                guard let self else { return }
                self.delegate?.captureOverlay(self, didFinish: payload)
            } catch {
                DiagnosticLog.record(error, phase: "render")
                guard let self else { return }
                self.isFinishing = false
                self.delegate?.captureOverlay(self, didFailWith: error)
            }
        }
    }

    private func appendArrow(
        to path: NSBezierPath,
        from start: CGPoint,
        to end: CGPoint,
        headLength: CGFloat
    ) {
        path.move(to: start)
        path.line(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread = CGFloat.pi / 7
        let first = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let second = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        path.move(to: first)
        path.line(to: end)
        path.line(to: second)
    }

    private func toolbarFrame() -> CGRect {
        guard let selection else { return .zero }
        let count = CGFloat(ToolbarAction.allCases.count)
        let width = count * Appearance.toolbarButtonSize
            + (count - 1) * Appearance.toolbarSpacing
            + Appearance.toolbarGroupGap
            + Appearance.toolbarPadding * 2
        let height = Appearance.toolbarButtonSize + Appearance.toolbarPadding * 2
        let x = min(max(selection.maxX - width, bounds.minX + 8), bounds.maxX - width - 8)
        let below = selection.maxY + 10
        let y = below + height <= bounds.maxY - 8 ? below : max(bounds.minY + 8, selection.minY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func toolbarButtonFrame(index: Int) -> CGRect {
        let toolbar = toolbarFrame()
        let groupOffset = index >= 3 ? Appearance.toolbarGroupGap : 0
        return CGRect(
            x: toolbar.minX
                + Appearance.toolbarPadding
                + CGFloat(index) * (Appearance.toolbarButtonSize + Appearance.toolbarSpacing)
                + groupOffset,
            y: toolbar.minY + Appearance.toolbarPadding,
            width: Appearance.toolbarButtonSize,
            height: Appearance.toolbarButtonSize
        )
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
