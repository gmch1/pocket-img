import AppKit
import CoreGraphics

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidStartSelection(_ overlay: CaptureOverlayView)
    func captureOverlayDidCancel(_ overlay: CaptureOverlayView)
    func captureOverlay(_ overlay: CaptureOverlayView, didFinish payload: UploadPayload)
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
        image.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

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
        isFinishing = true
        do {
            let payload = try renderPayload()
            delegate?.captureOverlay(self, didFinish: payload)
        } catch {
            isFinishing = false
            NSSound.beep()
        }
    }

    private func renderPayload() throws -> UploadPayload {
        guard let screenshot, let selection else { throw CaptureError.imageEncodingFailed }
        let scaleX = CGFloat(screenshot.width) / bounds.width
        let scaleY = CGFloat(screenshot.height) / bounds.height
        var pixelRect = CGRect(
            x: floor(selection.minX * scaleX),
            y: floor(selection.minY * scaleY),
            width: ceil(selection.width * scaleX),
            height: ceil(selection.height * scaleY)
        )
        pixelRect = pixelRect.intersection(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(screenshot.width),
            height: CGFloat(screenshot.height)
        ))
        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = screenshot.cropping(to: pixelRect) else {
            throw CaptureError.imageEncodingFailed
        }

        let maxPixels: CGFloat = 19_000_000
        let sourcePixels = CGFloat(cropped.width * cropped.height)
        let outputScale = min(1, sqrt(maxPixels / max(sourcePixels, 1)))
        let outputWidth = max(1, Int(CGFloat(cropped.width) * outputScale))
        let outputHeight = max(1, Int(CGFloat(cropped.height) * outputScale))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outputWidth,
            pixelsHigh: outputHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw CaptureError.imageEncodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let outputRect = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(outputWidth),
            height: CGFloat(outputHeight)
        )
        NSImage(cgImage: cropped, size: outputRect.size).draw(
            in: outputRect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )

        let annotationScaleX = CGFloat(outputWidth) / selection.width
        let annotationScaleY = CGFloat(outputHeight) / selection.height
        for annotation in annotations {
            drawRenderedAnnotation(
                annotation,
                selection: selection,
                scaleX: annotationScaleX,
                scaleY: annotationScaleY,
                outputHeight: CGFloat(outputHeight)
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        if let png = representation.representation(using: .png, properties: [:]), png.count <= 24 * 1024 * 1024 {
            return UploadPayload(data: png, fileName: "screenshot.png", contentType: "image/png")
        }
        guard let jpeg = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.88]
        ), jpeg.count <= 24 * 1024 * 1024 else {
            throw CaptureError.imageEncodingFailed
        }
        return UploadPayload(data: jpeg, fileName: "screenshot.jpg", contentType: "image/jpeg")
    }

    private func drawRenderedAnnotation(
        _ annotation: Annotation,
        selection: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        outputHeight: CGFloat
    ) {
        func outputPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - selection.minX) * scaleX,
                y: outputHeight - (point.y - selection.minY) * scaleY
            )
        }

        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = max(3, 3 * min(scaleX, scaleY))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.tool {
        case .rectangle:
            let first = outputPoint(annotation.start)
            let second = outputPoint(annotation.end)
            path.appendRect(CGRect.between(first, second))
        case .arrow:
            appendArrow(
                to: path,
                from: outputPoint(annotation.start),
                to: outputPoint(annotation.end),
                headLength: max(14, 14 * min(scaleX, scaleY))
            )
        }
        path.stroke()
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
