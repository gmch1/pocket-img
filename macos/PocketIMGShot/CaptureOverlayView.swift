import AppKit
import CoreGraphics

private extension AnnotationColor {
    var nsColor: NSColor {
        let components = components
        return NSColor(
            srgbRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }
}

final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private let horizontalPadding: CGFloat = 4

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(in: super.drawingRect(forBounds: rect))
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        start selectionStart: Int,
        length selectionLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            start: selectionStart,
            length: selectionLength
        )
    }

    private func centeredTextRect(in rect: NSRect) -> NSRect {
        let paddedWidth = max(0, rect.width - horizontalPadding * 2)
        guard let font else {
            return NSRect(
                x: rect.minX + horizontalPadding,
                y: rect.minY,
                width: paddedWidth,
                height: rect.height
            )
        }
        let lineHeight = min(
            rect.height,
            ceil(font.ascender - font.descender + font.leading)
        )
        return NSRect(
            x: rect.minX + horizontalPadding,
            y: rect.midY - lineHeight / 2,
            width: paddedWidth,
            height: lineHeight
        )
    }
}

enum CaptureAction: Sendable {
    case pin
    case copy
    case upload
}

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidStartSelection(_ overlay: CaptureOverlayView)
    func captureOverlayDidCancel(_ overlay: CaptureOverlayView)
    func captureOverlay(
        _ overlay: CaptureOverlayView,
        didFinish payload: UploadPayload,
        action: CaptureAction
    )
    func captureOverlay(_ overlay: CaptureOverlayView, didFailWith error: Error)
}

@MainActor
final class CaptureOverlayView: NSView, NSTextFieldDelegate {
    private struct PixelInspection {
        let crop: CGImage
        let cropRect: CGRect
        let pixelX: Int
        let pixelY: Int
        let red: Int
        let green: Int
        let blue: Int
    }

    private enum Appearance {
        static let toolbarButtonSize: CGFloat = 38
        static let toolbarPadding: CGFloat = 6
        static let toolbarSpacing: CGFloat = 4
        static let toolbarGroupGap: CGFloat = 8
        static let toolbarCornerRadius: CGFloat = 12
    }

    weak var delegate: CaptureOverlayViewDelegate?
    var onAnnotationStyleChange: ((AnnotationStylePreferences) -> Void)?
    var annotationStyle = AnnotationStylePreferences.default {
        didSet {
            let normalized = annotationStyle.normalized
            rectangleLineWidth = normalized.rectangleLineWidth
            arrowLineWidth = normalized.arrowLineWidth
            textFontSize = normalized.textFontSize
            annotationColor = normalized.resolvedColor
        }
    }
    var screenshot: CGImage? {
        didSet { needsDisplay = true }
    }
    var uploadEnabled = true {
        didSet { needsDisplay = true }
    }

    private enum Mode {
        case selecting
        case editing
    }

    private enum ToolbarAction: CaseIterable, Equatable {
        case rectangle
        case arrow
        case text
        case color
        case undo
        case cancel
        case pin
        case copy
        case upload
    }

    private var toolbarActions: [ToolbarAction] {
        if uploadEnabled {
            return ToolbarAction.allCases
        }
        return ToolbarAction.allCases.filter { $0 != .upload }
    }

    private var mode: Mode = .selecting
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var selectedTool: AnnotationTool = .rectangle
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var textEditor: NSTextField?
    private var textAnchor: CGPoint?
    private var textEditorSize: CGFloat?
    private var textEditorColor: AnnotationColor?
    private var hoverPoint: CGPoint?
    private var pressedToolbarAction: ToolbarAction?
    private var rectangleLineWidth: CGFloat = 2
    private var arrowLineWidth: CGFloat = 2
    private var textFontSize: CGFloat = 20
    private var annotationColor: AnnotationColor = .default
    private var colorPaletteVisible = false
    private var toolSizeHintVisible = false
    private var toolSizeHintGeneration = 0
    private var isFinishing = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .selecting ? .crosshair : .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        hoverPoint = point

        switch mode {
        case .selecting:
            delegate?.captureOverlayDidStartSelection(self)
            dragStart = point
            selection = CGRect(origin: point, size: .zero)
        case .editing:
            if colorPaletteVisible, let color = paletteColor(at: point) {
                commitTextEditing()
                selectAnnotationColor(color)
                return
            }
            if let action = toolbarAction(at: point) {
                commitTextEditing()
                pressedToolbarAction = action
                needsDisplay = true
                return
            }
            if colorPaletteVisible, !colorPaletteFrame().contains(point) {
                colorPaletteVisible = false
            }
            guard selection?.contains(point) == true else { return }
            if selectedTool == .text {
                beginTextEditing(at: point)
                return
            }
            commitTextEditing()
            dragStart = point
            currentAnnotation = Annotation(
                tool: selectedTool,
                start: point,
                end: point,
                styleSize: currentToolSize,
                color: annotationColor
            )
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFinishing, let dragStart else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        hoverPoint = point
        switch mode {
        case .selecting:
            selection = CGRect.between(dragStart, point).intersection(bounds)
        case .editing:
            guard let selection else { return }
            let endpoint = CGPoint(
                x: min(max(point.x, selection.minX), selection.maxX),
                y: min(max(point.y, selection.minY), selection.maxY)
            )
            currentAnnotation = Annotation(
                tool: selectedTool,
                start: dragStart,
                end: endpoint,
                styleSize: currentToolSize,
                color: annotationColor
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !isFinishing else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        if let pressedToolbarAction {
            self.pressedToolbarAction = nil
            if toolbarAction(at: point) == pressedToolbarAction {
                perform(pressedToolbarAction)
            }
            needsDisplay = true
            return
        }

        switch mode {
        case .selecting:
            guard let selection, selection.width >= 8, selection.height >= 8 else {
                self.selection = nil
                needsDisplay = true
                return
            }
            self.selection = selection.integral.intersection(bounds)
            mode = .editing
            hoverPoint = nil
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
            if uploadEnabled {
                finish(.upload)
            }
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": selectedTool = .rectangle
        case "a": selectedTool = .arrow
        case "t": selectedTool = .text
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mode == .editing,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            finish(.copy)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard mode == .editing, !isFinishing, abs(event.scrollingDeltaY) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        let rawStep = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 8
            : event.scrollingDeltaY
        switch selectedTool {
        case .rectangle:
            rectangleLineWidth = roundedHalfStep(rectangleLineWidth + rawStep, range: 1...12)
        case .arrow:
            arrowLineWidth = roundedHalfStep(arrowLineWidth + rawStep, range: 1...12)
        case .text:
            textFontSize = roundedWholeStep(textFontSize + rawStep * 2, range: 12...72)
            if let textEditor {
                let font = annotationTextFont(size: textFontSize)
                textEditor.font = font
                textEditorSize = textFontSize
                if let selection {
                    var frame = textEditor.frame
                    frame.size.height = textEditorHeight(for: font)
                    frame.origin.y = max(
                        selection.minY,
                        min(frame.origin.y, selection.maxY - frame.height)
                    )
                    textEditor.frame = frame
                    textAnchor = textAnchor(for: frame)
                }
            }
        }
        onAnnotationStyleChange?(currentAnnotationStyle)
        showToolSizeHint()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .selecting, !isFinishing else { return }
        hoverPoint = constrained(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let screenshot else {
            NSColor.black.setFill()
            NSBezierPath(rect: bounds).fill()
            return
        }

        let originalImage = NSImage(cgImage: screenshot, size: bounds.size)
        drawImage(originalImage, interpolation: .none)

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

        if mode == .selecting, let hoverPoint {
            drawPixelInspector(at: hoverPoint, screenshot: screenshot)
        }
    }

    private func drawImage(_ image: NSImage, interpolation: NSImageInterpolation) {
        let graphicsContext = NSGraphicsContext.current
        let previousInterpolation = graphicsContext?.imageInterpolation
        graphicsContext?.imageInterpolation = interpolation
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
            draw(annotation, color: annotation.color.nsColor)
        }
        if let currentAnnotation {
            draw(currentAnnotation, color: currentAnnotation.color.nsColor)
        }

        drawSizeLabel(selection)
        if mode == .editing {
            drawToolbar()
            if colorPaletteVisible { drawColorPalette() }
            if toolSizeHintVisible { drawToolSizeHint() }
        }
    }

    private func draw(_ annotation: Annotation, color: NSColor) {
        if annotation.tool == .text {
            drawText(annotation, color: color)
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.tool {
        case .rectangle:
            path.appendRect(annotation.rect)
        case .arrow:
            appendArrow(to: path, from: annotation.start, to: annotation.end, headLength: 14)
        case .text:
            return
        }

        let lineWidth = annotation.resolvedStyleSize
        color.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawText(_ annotation: Annotation, color: NSColor) {
        guard let value = annotation.text else { return }
        value.draw(
            at: annotation.start,
            withAttributes: [
                .font: NSFont.systemFont(
                    ofSize: annotation.resolvedStyleSize,
                    weight: .semibold
                ),
                .foregroundColor: color,
            ]
        )
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

        let separatorX = toolbarButtonFrame(index: 4).maxX
            + Appearance.toolbarSpacing
            + Appearance.toolbarGroupGap / 2
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: separatorX, y: frame.minY + 11))
        separator.line(to: CGPoint(x: separatorX, y: frame.maxY - 11))
        NSColor.white.withAlphaComponent(0.14).setStroke()
        separator.lineWidth = 1
        separator.stroke()

        for (index, action) in toolbarActions.enumerated() {
            let button = toolbarButtonFrame(index: index)
            let selected = (action == .rectangle && selectedTool == .rectangle)
                || (action == .arrow && selectedTool == .arrow)
                || (action == .text && selectedTool == .text)
                || (action == .color && colorPaletteVisible)
            if action == .upload {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            } else if action == .pin || action == .copy {
                NSColor.white.withAlphaComponent(0.14).setFill()
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
        case .text:
            path.move(to: CGPoint(x: icon.minX + 2, y: icon.maxY - 2))
            path.line(to: CGPoint(x: icon.midX, y: icon.minY + 2))
            path.line(to: CGPoint(x: icon.maxX - 2, y: icon.maxY - 2))
            path.move(to: CGPoint(x: icon.minX + 5, y: icon.midY + 2))
            path.line(to: CGPoint(x: icon.maxX - 5, y: icon.midY + 2))
        case .color:
            let swatch = icon.insetBy(dx: 1.5, dy: 1.5)
            annotationColor.nsColor.setFill()
            NSBezierPath(ovalIn: swatch).fill()
            color.setStroke()
            let outline = NSBezierPath(ovalIn: swatch)
            outline.lineWidth = 1.5
            outline.stroke()
            return
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
        case .pin:
            path.move(to: CGPoint(x: icon.minX + 4, y: icon.minY + 3))
            path.line(to: CGPoint(x: icon.maxX - 4, y: icon.minY + 3))
            path.move(to: CGPoint(x: icon.minX + 6, y: icon.minY + 3))
            path.line(to: CGPoint(x: icon.minX + 6, y: icon.midY - 1))
            path.line(to: CGPoint(x: icon.minX + 3, y: icon.midY + 3))
            path.line(to: CGPoint(x: icon.maxX - 3, y: icon.midY + 3))
            path.line(to: CGPoint(x: icon.maxX - 6, y: icon.midY - 1))
            path.line(to: CGPoint(x: icon.maxX - 6, y: icon.minY + 3))
            path.move(to: CGPoint(x: icon.midX, y: icon.midY + 3))
            path.line(to: CGPoint(x: icon.midX, y: icon.maxY - 1))
        case .copy:
            path.appendRoundedRect(
                CGRect(x: icon.minX + 1, y: icon.minY + 1, width: 11, height: 11),
                xRadius: 1.5,
                yRadius: 1.5
            )
            path.appendRoundedRect(
                CGRect(x: icon.minX + 6, y: icon.minY + 6, width: 11, height: 11),
                xRadius: 1.5,
                yRadius: 1.5
            )
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

    private func drawColorPalette() {
        let frame = colorPaletteFrame()
        let background = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(calibratedWhite: 0.08, alpha: 0.96).setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        background.lineWidth = 1
        background.stroke()

        for (index, color) in AnnotationColor.allCases.enumerated() {
            let swatch = colorSwatchFrame(index: index)
            color.nsColor.setFill()
            NSBezierPath(ovalIn: swatch).fill()

            let outline = NSBezierPath(ovalIn: swatch)
            if color == annotationColor {
                NSColor.white.setStroke()
                outline.lineWidth = 2.5
            } else {
                NSColor.black.withAlphaComponent(0.35).setStroke()
                outline.lineWidth = 1
            }
            outline.stroke()
        }
    }

    private func drawToolSizeHint() {
        let actionIndex: Int
        let suffix: String
        switch selectedTool {
        case .rectangle:
            actionIndex = 0
            suffix = "px"
        case .arrow:
            actionIndex = 1
            suffix = "px"
        case .text:
            actionIndex = 2
            suffix = "pt"
        }
        let size = currentToolSize
        let value = size.rounded() == size
            ? "\(Int(size)) \(suffix)"
            : String(format: "%.1f %@", size, suffix)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = value.size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 14, height: textSize.height + 8)
        let button = toolbarButtonFrame(index: actionIndex)
        let toolbar = toolbarFrame()
        let preferredY = toolbar.minY - badgeSize.height - 6
        let y = preferredY >= bounds.minY + 6
            ? preferredY
            : toolbar.maxY + 6
        let x = min(
            max(button.midX - badgeSize.width / 2, bounds.minX + 6),
            bounds.maxX - badgeSize.width - 6
        )
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).stroke()
        value.draw(
            at: CGPoint(x: frame.minX + 7, y: frame.minY + 4),
            withAttributes: attributes
        )
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

    private func drawPixelInspector(at point: CGPoint, screenshot: CGImage) {
        guard let inspection = pixelInspection(at: point, screenshot: screenshot) else { return }
        let frame = pixelInspectorFrame(near: point)
        let background = NSBezierPath(roundedRect: frame, xRadius: 11, yRadius: 11)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()

        let preview = CGRect(x: frame.minX + 8, y: frame.minY + 8, width: 150, height: 90)
        let previewPath = NSBezierPath(roundedRect: preview, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        previewPath.addClip()
        let image = NSImage(cgImage: inspection.crop, size: inspection.cropRect.size)
        let graphicsContext = NSGraphicsContext.current
        let previousInterpolation = graphicsContext?.imageInterpolation
        graphicsContext?.imageInterpolation = .none
        image.draw(
            in: preview,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        if let previousInterpolation {
            graphicsContext?.imageInterpolation = previousInterpolation
        }
        NSGraphicsContext.restoreGraphicsState()

        let focusX = preview.minX
            + (CGFloat(inspection.pixelX) + 0.5 - inspection.cropRect.minX)
            / inspection.cropRect.width * preview.width
        let focusY = preview.minY
            + (CGFloat(inspection.pixelY) + 0.5 - inspection.cropRect.minY)
            / inspection.cropRect.height * preview.height
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: focusX - 10, y: focusY))
        crosshair.line(to: CGPoint(x: focusX + 10, y: focusY))
        crosshair.move(to: CGPoint(x: focusX, y: focusY - 10))
        crosshair.line(to: CGPoint(x: focusX, y: focusY + 10))
        NSColor.black.withAlphaComponent(0.72).setStroke()
        crosshair.lineWidth = 3
        crosshair.stroke()
        NSColor.white.setStroke()
        crosshair.lineWidth = 1
        crosshair.stroke()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        previewPath.lineWidth = 1
        previewPath.stroke()
        background.lineWidth = 1
        background.stroke()

        let color = NSColor(
            srgbRed: CGFloat(inspection.red) / 255,
            green: CGFloat(inspection.green) / 255,
            blue: CGFloat(inspection.blue) / 255,
            alpha: 1
        )
        let swatch = CGRect(x: frame.minX + 10, y: frame.minY + 107, width: 18, height: 18)
        color.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4).stroke()

        let hex = String(
            format: "#%02X%02X%02X",
            inspection.red,
            inspection.green,
            inspection.blue
        )
        hex.draw(
            at: CGPoint(x: frame.minX + 36, y: frame.minY + 107),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        "\(inspection.pixelX), \(inspection.pixelY)".draw(
            at: CGPoint(x: frame.maxX - 58, y: frame.minY + 109),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.56),
            ]
        )
    }

    private func pixelInspection(at point: CGPoint, screenshot: CGImage) -> PixelInspection? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(screenshot.width) / bounds.width
        let scaleY = CGFloat(screenshot.height) / bounds.height
        let pixelX = min(max(Int(floor(point.x * scaleX)), 0), screenshot.width - 1)
        let pixelY = min(max(Int(floor(point.y * scaleY)), 0), screenshot.height - 1)
        let cropRect = CGRect(
            x: max(0, pixelX - 7),
            y: max(0, pixelY - 4),
            width: min(15, screenshot.width - max(0, pixelX - 7)),
            height: min(9, screenshot.height - max(0, pixelY - 4))
        ).integral
        guard let crop = screenshot.cropping(to: cropRect),
              let (red, green, blue) = sampleRGB(
                screenshot: screenshot,
                x: pixelX,
                y: pixelY
              ) else {
            return nil
        }
        return PixelInspection(
            crop: crop,
            cropRect: cropRect,
            pixelX: pixelX,
            pixelY: pixelY,
            red: red,
            green: green,
            blue: blue
        )
    }

    private func sampleRGB(screenshot: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let pixel = screenshot.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return nil }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    private func pixelInspectorFrame(near point: CGPoint) -> CGRect {
        let size = CGSize(width: 166, height: 136)
        var x = point.x + 18
        var y = point.y + 18
        if x + size.width > bounds.maxX - 8 { x = point.x - size.width - 18 }
        if y + size.height > bounds.maxY - 8 { y = point.y - size.height - 18 }
        x = min(max(x, bounds.minX + 8), bounds.maxX - size.width - 8)
        y = min(max(y, bounds.minY + 8), bounds.maxY - size.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func beginTextEditing(at point: CGPoint) {
        guard let selection else { return }
        commitTextEditing()

        let font = annotationTextFont(size: textFontSize)
        let width = min(280, selection.width)
        let height = textEditorHeight(for: font)
        let x = min(
            max(point.x, selection.minX),
            max(selection.minX, selection.maxX - width)
        )
        let y = min(
            max(point.y, selection.minY),
            max(selection.minY, selection.maxY - height)
        )
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let textColor = annotationColor.nsColor
        let editor = Self.makeEditableTextField(frame: frame, textColor: textColor)
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.font = font
        editor.focusRingType = .none
        editor.placeholderAttributedString = NSAttributedString(
            string: "输入文字",
            attributes: [
                .foregroundColor: textColor.withAlphaComponent(0.56),
            ]
        )
        editor.delegate = self
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.cell?.usesSingleLineMode = true
        editor.wantsLayer = true
        editor.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        editor.layer?.cornerRadius = 5
        editor.layer?.cornerCurve = .continuous
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        editor.layer?.masksToBounds = false

        addSubview(editor)
        textEditor = editor
        textAnchor = textAnchor(for: frame)
        textEditorSize = textFontSize
        textEditorColor = annotationColor
        window?.makeFirstResponder(editor)
        editor.selectText(nil)
        if let fieldEditor = editor.currentEditor() as? NSTextView {
            fieldEditor.insertionPointColor = textColor
            fieldEditor.backgroundColor = .clear
            fieldEditor.textColor = textColor
        }
        updateTextEditorFocus(true)
    }

    static func makeEditableTextField(frame: CGRect, textColor: NSColor) -> NSTextField {
        let editor = NSTextField(frame: frame)
        let cell = VerticallyCenteredTextFieldCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        editor.cell = cell
        editor.isEditable = true
        editor.isSelectable = true
        editor.isEnabled = true
        editor.textColor = textColor
        return editor
    }

    private func commitTextEditing() {
        guard let editor = textEditor else { return }
        let value = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = textAnchor
        let styleSize = textEditorSize
        let color = textEditorColor ?? annotationColor
        textEditor = nil
        textAnchor = nil
        textEditorSize = nil
        textEditorColor = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        if !value.isEmpty, let anchor {
            annotations.append(Annotation(
                tool: .text,
                start: anchor,
                end: anchor,
                text: value,
                styleSize: styleSize,
                color: color
            ))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func discardTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil
        textAnchor = nil
        textEditorSize = nil
        textEditorColor = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardTextEditing()
            return true
        }
        return false
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        updateTextEditorFocus(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        updateTextEditorFocus(false)
    }

    private func updateTextEditorFocus(_ focused: Bool) {
        guard let layer = textEditor?.layer else { return }
        layer.borderColor = focused
            ? NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
            : NSColor.white.withAlphaComponent(0.20).cgColor
        layer.borderWidth = focused ? 1.5 : 1
        layer.shadowColor = NSColor.controlAccentColor.cgColor
        layer.shadowOpacity = focused ? 0.20 : 0
        layer.shadowRadius = focused ? 5 : 0
        layer.shadowOffset = .zero
    }

    private func toolbarAction(at point: CGPoint) -> ToolbarAction? {
        guard toolbarFrame().contains(point) else { return nil }
        for (index, action) in toolbarActions.enumerated()
            where toolbarButtonFrame(index: index).contains(point) {
            return action
        }
        return nil
    }

    private func perform(_ action: ToolbarAction) {
        if action != .color {
            colorPaletteVisible = false
        }
        switch action {
        case .rectangle:
            selectedTool = .rectangle
        case .arrow:
            selectedTool = .arrow
        case .text:
            selectedTool = .text
        case .color:
            colorPaletteVisible.toggle()
        case .undo:
            if !annotations.isEmpty { annotations.removeLast() }
            currentAnnotation = nil
        case .cancel:
            delegate?.captureOverlayDidCancel(self)
        case .pin:
            finish(.pin)
        case .copy:
            finish(.copy)
        case .upload:
            if uploadEnabled {
                finish(.upload)
            }
        }
        needsDisplay = true
    }

    private func finish(_ action: CaptureAction) {
        guard mode == .editing, !isFinishing else { return }
        if case .upload = action, !uploadEnabled { return }
        commitTextEditing()
        guard let screenshot, let selection else {
            delegate?.captureOverlay(self, didFailWith: CaptureError.imageEncodingFailed)
            return
        }
        isFinishing = true
        let viewBounds = bounds
        let annotations = annotations
        let placementFrame = window.map { captureWindow in
            CaptureGeometry.screenFrame(for: selection, in: captureWindow.frame)
        }
        DiagnosticLog.record(
            "render started action=\(action) selection=\(Int(selection.width))x\(Int(selection.height)) " +
            "source=\(screenshot.width)x\(screenshot.height)"
        )

        Task { [weak self] in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotRenderer.render(
                        screenshot: screenshot,
                        viewBounds: viewBounds,
                        selection: selection,
                        annotations: annotations
                    )
                }.value
                let payload = placementFrame.map { rendered.placed(in: $0) } ?? rendered
                DiagnosticLog.record("render finished bytes=\(payload.data.count)")
                guard let self else { return }
                self.delegate?.captureOverlay(self, didFinish: payload, action: action)
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
        let count = CGFloat(toolbarActions.count)
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
        let groupOffset = index >= 5 ? Appearance.toolbarGroupGap : 0
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

    private func colorPaletteFrame() -> CGRect {
        let swatchSize: CGFloat = 22
        let spacing: CGFloat = 7
        let padding: CGFloat = 8
        let count = CGFloat(AnnotationColor.allCases.count)
        let width = count * swatchSize + (count - 1) * spacing + padding * 2
        let height = swatchSize + padding * 2
        let colorButton = toolbarButtonFrame(index: 3)
        let toolbar = toolbarFrame()
        let x = min(
            max(colorButton.midX - width / 2, bounds.minX + 6),
            bounds.maxX - width - 6
        )
        let above = toolbar.minY - height - 6
        let y = above >= bounds.minY + 6 ? above : toolbar.maxY + 6
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func colorSwatchFrame(index: Int) -> CGRect {
        let palette = colorPaletteFrame()
        let swatchSize: CGFloat = 22
        let spacing: CGFloat = 7
        return CGRect(
            x: palette.minX + 8 + CGFloat(index) * (swatchSize + spacing),
            y: palette.minY + 8,
            width: swatchSize,
            height: swatchSize
        )
    }

    private func paletteColor(at point: CGPoint) -> AnnotationColor? {
        guard colorPaletteFrame().contains(point) else { return nil }
        for (index, color) in AnnotationColor.allCases.enumerated()
            where colorSwatchFrame(index: index).insetBy(dx: -3, dy: -3).contains(point) {
            return color
        }
        return nil
    }

    private func selectAnnotationColor(_ color: AnnotationColor) {
        annotationColor = color
        colorPaletteVisible = false
        onAnnotationStyleChange?(currentAnnotationStyle)
        needsDisplay = true
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private var currentToolSize: CGFloat {
        switch selectedTool {
        case .rectangle:
            return rectangleLineWidth
        case .arrow:
            return arrowLineWidth
        case .text:
            return textFontSize
        }
    }

    private var currentAnnotationStyle: AnnotationStylePreferences {
        AnnotationStylePreferences(
            rectangleLineWidth: rectangleLineWidth,
            arrowLineWidth: arrowLineWidth,
            textFontSize: textFontSize,
            color: annotationColor
        )
    }

    private func roundedHalfStep(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max((value * 2).rounded() / 2, range.lowerBound), range.upperBound)
    }

    private func roundedWholeStep(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value.rounded(), range.lowerBound), range.upperBound)
    }

    private func showToolSizeHint() {
        toolSizeHintGeneration += 1
        let generation = toolSizeHintGeneration
        toolSizeHintVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.toolSizeHintGeneration == generation else { return }
            self.toolSizeHintVisible = false
            self.needsDisplay = true
        }
    }

    private func annotationTextFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func textEditorHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 2
    }

    private func textAnchor(for editorFrame: CGRect) -> CGPoint {
        CGPoint(x: editorFrame.minX + 4, y: editorFrame.minY + 1)
    }
}
