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

        NSColor.black.withAlphaComponent(0.48).setFill()
        if let selection {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(selection)
            shade.windingRule = .evenOdd
            shade.fill()
            drawSelection(selection)
        } else {
            NSBezierPath(rect: bounds).fill()
            drawCenteredHint("拖拽选择截图区域 · Esc 取消")
        }
    }

    private func drawSelection(_ selection: CGRect) {
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        NSColor.white.withAlphaComponent(0.92).setStroke()
        border.lineWidth = 1
        border.stroke()

        let accent = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        NSColor.controlAccentColor.setStroke()
        accent.lineWidth = 1
        accent.stroke()

        for annotation in annotations {
            draw(annotation, color: .systemRed)
        }
        if let currentAnnotation {
            draw(currentAnnotation, color: .systemRed)
        }

        if mode == .editing {
            drawToolbar()
        } else {
            drawSizeLabel(selection)
        }
    }

    private func draw(_ annotation: Annotation, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.tool {
        case .rectangle:
            path.appendRect(annotation.rect)
        case .arrow:
            appendArrow(to: path, from: annotation.start, to: annotation.end, headLength: 14)
        }
        path.stroke()
    }

    private func drawToolbar() {
        let frame = toolbarFrame()
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()

        for (index, action) in ToolbarAction.allCases.enumerated() {
            let button = toolbarButtonFrame(index: index)
            let selected = (action == .rectangle && selectedTool == .rectangle)
                || (action == .arrow && selectedTool == .arrow)
            if action == .upload {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: button.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
            } else if selected {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: button.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5).fill()
            }
            let color: NSColor = action == .upload || selected ? .white : .lightGray
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
            path.appendOval(in: icon.insetBy(dx: 1, dy: 1))
            path.move(to: CGPoint(x: icon.midX, y: icon.maxY - 4))
            path.line(to: CGPoint(x: icon.midX, y: icon.minY + 4))
            path.move(to: CGPoint(x: icon.midX - 4, y: icon.minY + 8))
            path.line(to: CGPoint(x: icon.midX, y: icon.minY + 4))
            path.line(to: CGPoint(x: icon.midX + 4, y: icon.minY + 8))
        }
        path.stroke()
    }

    private func drawSizeLabel(_ selection: CGRect) {
        guard selection.width >= 50 else { return }
        let value = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        value.draw(at: NSPoint(x: selection.minX + 5, y: selection.minY + 5), withAttributes: attributes)
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
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
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
        let buttonSize: CGFloat = 36
        let padding: CGFloat = 4
        let width = CGFloat(ToolbarAction.allCases.count) * buttonSize + padding * 2
        let height = buttonSize + padding * 2
        let x = min(max(selection.maxX - width, bounds.minX + 8), bounds.maxX - width - 8)
        let below = selection.maxY + 8
        let y = below + height <= bounds.maxY - 8 ? below : max(bounds.minY + 8, selection.minY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func toolbarButtonFrame(index: Int) -> CGRect {
        let toolbar = toolbarFrame()
        return CGRect(x: toolbar.minX + 4 + CGFloat(index) * 36, y: toolbar.minY + 4, width: 36, height: 36)
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
