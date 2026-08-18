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
        static let toolbarButtonSize: CGFloat = 24
        static let toolbarIconSize: CGFloat = 16
        static let toolbarButtonCornerRadius: CGFloat = 5
        static let toolbarPadding: CGFloat = 4
        static let toolbarSpacing: CGFloat = 2
        static let toolbarGroupGap: CGFloat = 5
        static let toolbarCornerRadius: CGFloat = 8
        static let selectionHandleSize: CGFloat = 7
        static let selectionHandleHitSize: CGFloat = 14
    }

    private enum AnnotationResizeHandle: Equatable {
        case rectangleTopLeft
        case rectangleTopRight
        case rectangleBottomLeft
        case rectangleBottomRight
        case arrowStart
        case arrowEnd
        case textScale
    }

    private struct AnnotationHit {
        let index: Int
        let resizeHandle: AnnotationResizeHandle?
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
    private var selectionAtDragStart: CGRect?
    private var selectionResizeHandle: SelectionResizeHandle?
    private var hoveredSelectionResizeHandle: SelectionResizeHandle?
    private var annotationsAtDragStart: [Annotation]?
    private var selection: CGRect?
    private var selectedTool: AnnotationTool? {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var selectedAnnotationIndex: Int?
    private var hoveredAnnotationHit: AnnotationHit?
    private var annotationAtDragStart: Annotation?
    private var annotationResizeHandle: AnnotationResizeHandle?
    private var textEditor: NSTextField?
    private var textAnchor: CGPoint?
    private var textEditorVerticalCenter: CGFloat?
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
    private var toolSizeHintTool: AnnotationTool?
    private var toolSizeHintGeneration = 0
    private var isFinishing = false
    private lazy var northwestSoutheastResizeCursor = Self.makeDiagonalResizeCursor(falling: true)
    private lazy var northeastSouthwestResizeCursor = Self.makeDiagonalResizeCursor(falling: false)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        if mode == .selecting {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        addCursorRect(bounds, cursor: .arrow)
        if let selection {
            if let selectionResizeHandle {
                addCursorRect(bounds, cursor: cursor(for: selectionResizeHandle))
                return
            }
            let isMoving = selectionAtDragStart != nil
                || (annotationAtDragStart != nil && annotationResizeHandle == nil)
            addCursorRect(
                selection,
                cursor: isMoving
                    ? .closedHand
                    : (selectedTool == nil ? .openHand : .crosshair)
            )
            if let hoveredAnnotationHit,
               hoveredAnnotationHit.resizeHandle == nil,
               let hoverPoint,
               annotations.indices.contains(hoveredAnnotationHit.index) {
                let hoverCursorRect = CGRect(
                    x: hoverPoint.x - 3,
                    y: hoverPoint.y - 3,
                    width: 6,
                    height: 6
                ).intersection(selection)
                addCursorRect(
                    hoverCursorRect,
                    cursor: annotationAtDragStart == nil ? .openHand : .closedHand
                )
            }
            let controlIndex = hoveredAnnotationHit?.index ?? selectedAnnotationIndex
            if let controlIndex, annotations.indices.contains(controlIndex) {
                for (handle, frame) in annotationResizeHandles(for: annotations[controlIndex]) {
                    addCursorRect(
                        frame.insetBy(dx: -3, dy: -3),
                        cursor: cursor(for: handle)
                    )
                }
            }
            for (handle, frame) in selectionResizeHandleFrames(for: selection) {
                addCursorRect(frame, cursor: cursor(for: handle))
            }
        }
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
            guard let selection else { return }
            commitTextEditing()
            if let handle = selectionResizeHandle(at: point, in: selection) {
                dragStart = point
                selectionAtDragStart = selection
                selectionResizeHandle = handle
                annotationsAtDragStart = nil
                annotationAtDragStart = nil
                annotationResizeHandle = nil
                selectedAnnotationIndex = nil
                hoveredAnnotationHit = nil
                hoveredSelectionResizeHandle = handle
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }
            guard selection.contains(point) else { return }
            if let hit = editableAnnotationHit(at: point) {
                dragStart = point
                selectedAnnotationIndex = hit.index
                annotationAtDragStart = annotations[hit.index]
                annotationResizeHandle = hit.resizeHandle
                selectionAtDragStart = nil
                annotationsAtDragStart = nil
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }
            if selectedTool == .text {
                selectedAnnotationIndex = nil
                hoveredAnnotationHit = nil
                beginTextEditing(at: point)
                window?.invalidateCursorRects(for: self)
                return
            }
            dragStart = point
            guard let selectedTool else {
                selectedAnnotationIndex = nil
                selectionAtDragStart = selection
                annotationsAtDragStart = annotations
                window?.invalidateCursorRects(for: self)
                return
            }
            selectedAnnotationIndex = nil
            hoveredAnnotationHit = nil
            currentAnnotation = Annotation(
                tool: selectedTool,
                start: point,
                end: point,
                styleSize: toolSize(for: selectedTool),
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
            if let selectionResizeHandle,
               let originalSelection = selectionAtDragStart {
                self.selection = CaptureGeometry.resizedSelection(
                    originalSelection,
                    using: selectionResizeHandle,
                    to: point,
                    within: bounds
                )
                hoveredSelectionResizeHandle = selectionResizeHandle
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }
            if let originalAnnotation = annotationAtDragStart,
               let selectedAnnotationIndex,
               annotations.indices.contains(selectedAnnotationIndex) {
                if let annotationResizeHandle {
                    annotations[selectedAnnotationIndex] = resizedAnnotation(
                        originalAnnotation,
                        using: annotationResizeHandle,
                        to: point,
                        within: selection
                    )
                } else {
                    let annotationBounds = annotationInteractionBounds(originalAnnotation)
                    let offset = CaptureGeometry.clampedMovementOffset(
                        moving: annotationBounds,
                        from: dragStart,
                        to: point,
                        within: selection
                    )
                    annotations[selectedAnnotationIndex] = originalAnnotation.translatedBy(
                        x: offset.x,
                        y: offset.y
                    )
                }
                hoveredAnnotationHit = AnnotationHit(
                    index: selectedAnnotationIndex,
                    resizeHandle: annotationResizeHandle
                )
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }
            guard let selectedTool else {
                guard let originalSelection = selectionAtDragStart,
                      let originalAnnotations = annotationsAtDragStart else { return }
                let movedSelection = CaptureGeometry.movedSelection(
                    originalSelection,
                    from: dragStart,
                    to: point,
                    within: bounds
                )
                let offsetX = movedSelection.minX - originalSelection.minX
                let offsetY = movedSelection.minY - originalSelection.minY
                self.selection = movedSelection
                annotations = originalAnnotations.map {
                    $0.translatedBy(x: offsetX, y: offsetY)
                }
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }
            let endpoint = CGPoint(
                x: min(max(point.x, selection.minX), selection.maxX),
                y: min(max(point.y, selection.minY), selection.maxY)
            )
            currentAnnotation = Annotation(
                tool: selectedTool,
                start: dragStart,
                end: endpoint,
                styleSize: toolSize(for: selectedTool),
                color: annotationColor
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            selectionAtDragStart = nil
            selectionResizeHandle = nil
            annotationsAtDragStart = nil
            annotationAtDragStart = nil
            annotationResizeHandle = nil
            window?.invalidateCursorRects(for: self)
        }
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
            hoveredSelectionResizeHandle = selection.flatMap {
                selectionResizeHandle(at: point, in: $0)
            }
            if let annotation = currentAnnotation, annotation.isMeaningful {
                annotations.append(annotation)
                selectedAnnotationIndex = annotations.indices.last
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
            selectedAnnotationIndex = nil
            hoveredAnnotationHit = nil
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
        case "r": toggleAnnotationTool(.rectangle)
        case "a": toggleAnnotationTool(.arrow)
        case "t": toggleAnnotationTool(.text)
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
        let targetTool: AnnotationTool
        let currentSize: CGFloat
        if let currentAnnotation {
            targetTool = currentAnnotation.tool
            currentSize = currentAnnotation.resolvedStyleSize
        } else if textEditor != nil {
            targetTool = .text
            currentSize = textEditorSize ?? textFontSize
        } else if let selectedAnnotationIndex,
                  annotations.indices.contains(selectedAnnotationIndex) {
            let annotation = annotations[selectedAnnotationIndex]
            targetTool = annotation.tool
            currentSize = annotation.resolvedStyleSize
        } else if let selectedTool {
            targetTool = selectedTool
            currentSize = toolSize(for: selectedTool)
        } else {
            super.scrollWheel(with: event)
            return
        }
        let rawStep = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 8
            : event.scrollingDeltaY
        let updatedSize: CGFloat
        switch targetTool {
        case .rectangle:
            updatedSize = roundedHalfStep(currentSize + rawStep, range: 1...12)
        case .arrow:
            updatedSize = roundedHalfStep(currentSize + rawStep, range: 1...12)
        case .text:
            updatedSize = roundedWholeStep(currentSize + rawStep * 2, range: 12...72)
        }
        setToolSize(updatedSize, for: targetTool)
        if let currentAnnotation {
            self.currentAnnotation = currentAnnotation.withStyleSize(updatedSize)
        } else if let textEditor {
            updateTextEditor(textEditor, fontSize: updatedSize)
        } else if let selectedAnnotationIndex,
                  annotations.indices.contains(selectedAnnotationIndex) {
            annotations[selectedAnnotationIndex] = annotations[selectedAnnotationIndex]
                .withStyleSize(updatedSize)
        }
        onAnnotationStyleChange?(currentAnnotationStyle)
        showToolSizeHint(for: targetTool)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isFinishing else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        switch mode {
        case .selecting:
            hoverPoint = point
            needsDisplay = true
        case .editing:
            hoveredSelectionResizeHandle = selection.flatMap {
                selectionResizeHandle(at: point, in: $0)
            }
            hoveredAnnotationHit = hoveredSelectionResizeHandle == nil
                ? editableAnnotationHit(at: point)
                : nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
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

        if mode == .editing {
            drawSelectionResizeHandles(for: selection)
        }

        for annotation in annotations {
            draw(annotation, color: annotation.color.nsColor)
        }
        if let currentAnnotation {
            draw(currentAnnotation, color: currentAnnotation.color.nsColor)
        }
        let controlIndex = hoveredAnnotationHit?.index ?? selectedAnnotationIndex
        if let controlIndex, annotations.indices.contains(controlIndex) {
            drawAnnotationControls(for: annotations[controlIndex])
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

    private func drawAnnotationControls(for annotation: Annotation) {
        let outline = NSBezierPath()
        if annotation.tool == .arrow {
            outline.move(to: annotation.start)
            outline.line(to: annotation.end)
        } else {
            outline.appendRoundedRect(
                annotationInteractionBounds(annotation).insetBy(dx: -3, dy: -3),
                xRadius: 3,
                yRadius: 3
            )
        }
        NSColor.controlAccentColor.withAlphaComponent(0.82).setStroke()
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()

        for (_, frame) in annotationResizeHandles(for: annotation) {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.controlAccentColor.setStroke()
            let handleOutline = NSBezierPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 1.5,
                yRadius: 1.5
            )
            handleOutline.lineWidth = 1.5
            handleOutline.stroke()
        }
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
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
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
        separator.move(to: CGPoint(x: separatorX, y: frame.minY + 8))
        separator.line(to: CGPoint(x: separatorX, y: frame.maxY - 8))
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
                NSBezierPath(
                    roundedRect: button,
                    xRadius: Appearance.toolbarButtonCornerRadius,
                    yRadius: Appearance.toolbarButtonCornerRadius
                ).fill()
            } else if action == .pin || action == .copy {
                NSColor.white.withAlphaComponent(0.14).setFill()
                NSBezierPath(
                    roundedRect: button,
                    xRadius: Appearance.toolbarButtonCornerRadius,
                    yRadius: Appearance.toolbarButtonCornerRadius
                ).fill()
            } else if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.72).setFill()
                NSBezierPath(
                    roundedRect: button,
                    xRadius: Appearance.toolbarButtonCornerRadius,
                    yRadius: Appearance.toolbarButtonCornerRadius
                ).fill()
            } else if action == .cancel {
                NSColor.systemRed.withAlphaComponent(0.14).setFill()
                NSBezierPath(
                    roundedRect: button,
                    xRadius: Appearance.toolbarButtonCornerRadius,
                    yRadius: Appearance.toolbarButtonCornerRadius
                ).fill()
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
        let iconSize = Appearance.toolbarIconSize
        let icon = CGRect(
            x: button.midX - iconSize / 2,
            y: button.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
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
                CGRect(x: icon.minX + 2.5, y: icon.minY + 2, width: 11, height: 13),
                xRadius: 2,
                yRadius: 2
            )
            path.appendRoundedRect(
                CGRect(x: icon.midX - 3, y: icon.minY + 1, width: 6, height: 3.5),
                xRadius: 1,
                yRadius: 1
            )
            for offset in [CGFloat(7), 10, 13] {
                path.move(to: CGPoint(x: icon.minX + 5, y: icon.minY + offset))
                path.line(to: CGPoint(x: icon.maxX - 5, y: icon.minY + offset))
            }
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
        guard let toolSizeHintTool else { return }
        let actionIndex: Int
        let suffix: String
        switch toolSizeHintTool {
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
        let size = toolSize(for: toolSizeHintTool)
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
        let width = textEditorWidth(for: "", font: font, maximum: selection.width)
        let height = textEditorHeight(for: font)
        let frame = CaptureGeometry.textEditorFrame(
            for: point,
            size: CGSize(width: width, height: height),
            within: selection
        )
        let textColor = annotationColor.nsColor
        let editor = Self.makeEditableTextField(frame: frame, textColor: textColor)
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.font = font
        editor.focusRingType = .none
        Self.updateTextEditorPlaceholder(editor, font: font, textColor: textColor)
        editor.delegate = self
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.cell?.usesSingleLineMode = true
        editor.wantsLayer = true
        editor.layer?.backgroundColor = NSColor.clear.cgColor
        editor.layer?.cornerRadius = 4
        editor.layer?.cornerCurve = .continuous
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        editor.layer?.masksToBounds = false

        addSubview(editor)
        textEditor = editor
        textAnchor = textAnchor(for: frame, font: font)
        textEditorVerticalCenter = point.y
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

    static func updateTextEditorPlaceholder(
        _ editor: NSTextField,
        font: NSFont,
        textColor: NSColor
    ) {
        editor.placeholderAttributedString = NSAttributedString(
            string: "输入文字",
            attributes: [
                .font: font,
                .foregroundColor: textColor.withAlphaComponent(0.56),
            ]
        )
    }

    private func commitTextEditing() {
        guard let editor = textEditor else { return }
        let value = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = textAnchor
        let styleSize = textEditorSize
        let color = textEditorColor ?? annotationColor
        textEditor = nil
        textAnchor = nil
        textEditorVerticalCenter = nil
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
            selectedAnnotationIndex = annotations.indices.last
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func discardTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil
        textAnchor = nil
        textEditorVerticalCenter = nil
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

    func controlTextDidChange(_ notification: Notification) {
        resizeTextEditorToFit()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        updateTextEditorFocus(false)
    }

    private func updateTextEditorFocus(_ focused: Bool) {
        guard let layer = textEditor?.layer else { return }
        layer.borderColor = focused
            ? NSColor.controlAccentColor.withAlphaComponent(0.76).cgColor
            : NSColor.white.withAlphaComponent(0.14).cgColor
        layer.borderWidth = 1
        layer.shadowColor = NSColor.controlAccentColor.cgColor
        layer.shadowOpacity = focused ? 0.12 : 0
        layer.shadowRadius = focused ? 3 : 0
        layer.shadowOffset = .zero
    }

    private func resizeTextEditorToFit() {
        guard let editor = textEditor,
              let selection,
              let font = editor.font else { return }
        var frame = editor.frame
        frame.size.width = textEditorWidth(
            for: editor.stringValue,
            font: font,
            maximum: selection.maxX - frame.minX
        )
        frame.size.height = textEditorHeight(for: font)
        frame = CaptureGeometry.textEditorFrame(
            for: CGPoint(
                x: frame.minX,
                y: textEditorVerticalCenter ?? frame.midY
            ),
            size: frame.size,
            within: selection
        )
        editor.frame = frame
        textAnchor = textAnchor(for: frame, font: font)
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
            toggleAnnotationTool(.rectangle)
        case .arrow:
            toggleAnnotationTool(.arrow)
        case .text:
            toggleAnnotationTool(.text)
        case .color:
            colorPaletteVisible.toggle()
        case .undo:
            if !annotations.isEmpty { annotations.removeLast() }
            currentAnnotation = nil
            selectedAnnotationIndex = nil
            hoveredAnnotationHit = nil
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

    private func selectionResizeHandleFrames(
        for selection: CGRect
    ) -> [(SelectionResizeHandle, CGRect)] {
        let hitSize = Appearance.selectionHandleHitSize
        let halfHitSize = hitSize / 2
        func frame(center: CGPoint) -> CGRect {
            CGRect(
                x: center.x - halfHitSize,
                y: center.y - halfHitSize,
                width: hitSize,
                height: hitSize
            )
        }
        return [
            (.top, CGRect(
                x: selection.minX + halfHitSize,
                y: selection.minY - halfHitSize,
                width: max(0, selection.width - hitSize),
                height: hitSize
            )),
            (.right, CGRect(
                x: selection.maxX - halfHitSize,
                y: selection.minY + halfHitSize,
                width: hitSize,
                height: max(0, selection.height - hitSize)
            )),
            (.bottom, CGRect(
                x: selection.minX + halfHitSize,
                y: selection.maxY - halfHitSize,
                width: max(0, selection.width - hitSize),
                height: hitSize
            )),
            (.left, CGRect(
                x: selection.minX - halfHitSize,
                y: selection.minY + halfHitSize,
                width: hitSize,
                height: max(0, selection.height - hitSize)
            )),
            (.topLeft, frame(center: selectionResizeHandleCenter(.topLeft, in: selection))),
            (.topRight, frame(center: selectionResizeHandleCenter(.topRight, in: selection))),
            (.bottomRight, frame(center: selectionResizeHandleCenter(.bottomRight, in: selection))),
            (.bottomLeft, frame(center: selectionResizeHandleCenter(.bottomLeft, in: selection))),
        ]
    }

    private func selectionResizeHandleCenter(
        _ handle: SelectionResizeHandle,
        in selection: CGRect
    ) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: selection.minX, y: selection.minY)
        case .top:
            return CGPoint(x: selection.midX, y: selection.minY)
        case .topRight:
            return CGPoint(x: selection.maxX, y: selection.minY)
        case .right:
            return CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight:
            return CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottom:
            return CGPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft:
            return CGPoint(x: selection.minX, y: selection.maxY)
        case .left:
            return CGPoint(x: selection.minX, y: selection.midY)
        }
    }

    private func selectionResizeHandle(
        at point: CGPoint,
        in selection: CGRect
    ) -> SelectionResizeHandle? {
        let frames = selectionResizeHandleFrames(for: selection)
        let corners: Set<SelectionResizeHandle> = [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
        ]
        return frames.first { corners.contains($0.0) && $0.1.contains(point) }?.0
            ?? frames.first { $0.1.contains(point) }?.0
    }

    private func drawSelectionResizeHandles(for selection: CGRect) {
        for handle in SelectionResizeHandle.allCases {
            let size = handle == hoveredSelectionResizeHandle
                ? Appearance.selectionHandleSize + 2
                : Appearance.selectionHandleSize
            let center = selectionResizeHandleCenter(handle, in: selection)
            let frame = CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: frame).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    private func cursor(for handle: SelectionResizeHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return northwestSoutheastResizeCursor
        case .topRight, .bottomLeft:
            return northeastSouthwestResizeCursor
        }
    }

    private func cursor(for handle: AnnotationResizeHandle) -> NSCursor {
        switch handle {
        case .rectangleTopLeft, .rectangleBottomRight, .textScale:
            return northwestSoutheastResizeCursor
        case .rectangleTopRight, .rectangleBottomLeft:
            return northeastSouthwestResizeCursor
        case .arrowStart, .arrowEnd:
            return .crosshair
        }
    }

    private static func makeDiagonalResizeCursor(falling: Bool) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            let start = falling ? CGPoint(x: 5, y: 19) : CGPoint(x: 5, y: 5)
            let end = falling ? CGPoint(x: 19, y: 5) : CGPoint(x: 19, y: 19)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: start)
            path.line(to: end)
            if falling {
                path.move(to: start)
                path.line(to: CGPoint(x: 5, y: 13))
                path.move(to: start)
                path.line(to: CGPoint(x: 11, y: 19))
                path.move(to: end)
                path.line(to: CGPoint(x: 19, y: 11))
                path.move(to: end)
                path.line(to: CGPoint(x: 13, y: 5))
            } else {
                path.move(to: start)
                path.line(to: CGPoint(x: 5, y: 11))
                path.move(to: start)
                path.line(to: CGPoint(x: 11, y: 5))
                path.move(to: end)
                path.line(to: CGPoint(x: 19, y: 13))
                path.move(to: end)
                path.line(to: CGPoint(x: 13, y: 19))
            }
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private func annotationHit(at point: CGPoint) -> AnnotationHit? {
        var controlIndices: [Int] = []
        if let hoveredIndex = hoveredAnnotationHit?.index {
            controlIndices.append(hoveredIndex)
        }
        if let selectedAnnotationIndex, !controlIndices.contains(selectedAnnotationIndex) {
            controlIndices.append(selectedAnnotationIndex)
        }
        for index in controlIndices where annotations.indices.contains(index) {
            for (handle, frame) in annotationResizeHandles(for: annotations[index])
                where frame.insetBy(dx: -4, dy: -4).contains(point) {
                return AnnotationHit(index: index, resizeHandle: handle)
            }
        }

        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            if annotationContains(annotation, point: point) {
                return AnnotationHit(index: index, resizeHandle: nil)
            }
        }
        return nil
    }

    private func editableAnnotationHit(at point: CGPoint) -> AnnotationHit? {
        guard selectedTool != nil else {
            return annotationHit(at: point)
        }
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex) else {
            return nil
        }
        let annotation = annotations[selectedAnnotationIndex]
        for (handle, frame) in annotationResizeHandles(for: annotation)
            where frame.insetBy(dx: -4, dy: -4).contains(point) {
            return AnnotationHit(index: selectedAnnotationIndex, resizeHandle: handle)
        }
        guard annotationContains(annotation, point: point) else {
            return nil
        }
        return AnnotationHit(index: selectedAnnotationIndex, resizeHandle: nil)
    }

    private func annotationContains(
        _ annotation: Annotation,
        point: CGPoint
    ) -> Bool {
        switch annotation.tool {
        case .rectangle:
            let tolerance = max(6, annotation.resolvedStyleSize / 2 + 4)
            return CaptureGeometry.rectangleOutline(
                annotation.rect,
                contains: point,
                tolerance: tolerance
            )
        case .arrow:
            let tolerance = max(6, annotation.resolvedStyleSize / 2 + 4)
            return distance(from: point, toSegmentFrom: annotation.start, to: annotation.end)
                <= tolerance
        case .text:
            return annotationInteractionBounds(annotation)
                .insetBy(dx: -5, dy: -5)
                .contains(point)
        }
    }

    private func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let squaredLength = deltaX * deltaX + deltaY * deltaY
        guard squaredLength > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = min(
            1,
            max(
                0,
                ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY)
                    / squaredLength
            )
        )
        let nearest = CGPoint(
            x: start.x + projection * deltaX,
            y: start.y + projection * deltaY
        )
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private func annotationInteractionBounds(_ annotation: Annotation) -> CGRect {
        switch annotation.tool {
        case .rectangle:
            return annotation.rect
        case .arrow:
            return CGRect.between(annotation.start, annotation.end)
                .insetBy(dx: -1, dy: -1)
        case .text:
            guard let value = annotation.text else {
                return CGRect(origin: annotation.start, size: .zero)
            }
            let font = annotationTextFont(size: annotation.resolvedStyleSize)
            let size = value.size(withAttributes: [.font: font])
            return CGRect(origin: annotation.start, size: size)
        }
    }

    private func annotationResizeHandles(
        for annotation: Annotation
    ) -> [(AnnotationResizeHandle, CGRect)] {
        let size: CGFloat = 7
        func frame(center: CGPoint) -> CGRect {
            CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
        }

        switch annotation.tool {
        case .rectangle:
            let rect = annotation.rect
            return [
                (.rectangleTopLeft, frame(center: CGPoint(x: rect.minX, y: rect.minY))),
                (.rectangleTopRight, frame(center: CGPoint(x: rect.maxX, y: rect.minY))),
                (.rectangleBottomLeft, frame(center: CGPoint(x: rect.minX, y: rect.maxY))),
                (.rectangleBottomRight, frame(center: CGPoint(x: rect.maxX, y: rect.maxY))),
            ]
        case .arrow:
            return [
                (.arrowStart, frame(center: annotation.start)),
                (.arrowEnd, frame(center: annotation.end)),
            ]
        case .text:
            let bounds = annotationInteractionBounds(annotation)
            return [
                (.textScale, frame(center: CGPoint(x: bounds.maxX, y: bounds.maxY))),
            ]
        }
    }

    private func resizedAnnotation(
        _ annotation: Annotation,
        using handle: AnnotationResizeHandle,
        to point: CGPoint,
        within selection: CGRect
    ) -> Annotation {
        let point = CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX),
            y: min(max(point.y, selection.minY), selection.maxY)
        )
        switch handle {
        case .rectangleTopLeft,
             .rectangleTopRight,
             .rectangleBottomLeft,
             .rectangleBottomRight:
            guard annotation.tool == .rectangle else { return annotation }
            let rect = annotation.rect
            let opposite: CGPoint
            var endpoint = point
            switch handle {
            case .rectangleTopLeft:
                opposite = CGPoint(x: rect.maxX, y: rect.maxY)
                endpoint.x = min(endpoint.x, opposite.x - 3)
                endpoint.y = min(endpoint.y, opposite.y - 3)
            case .rectangleTopRight:
                opposite = CGPoint(x: rect.minX, y: rect.maxY)
                endpoint.x = max(endpoint.x, opposite.x + 3)
                endpoint.y = min(endpoint.y, opposite.y - 3)
            case .rectangleBottomLeft:
                opposite = CGPoint(x: rect.maxX, y: rect.minY)
                endpoint.x = min(endpoint.x, opposite.x - 3)
                endpoint.y = max(endpoint.y, opposite.y + 3)
            case .rectangleBottomRight:
                opposite = CGPoint(x: rect.minX, y: rect.minY)
                endpoint.x = max(endpoint.x, opposite.x + 3)
                endpoint.y = max(endpoint.y, opposite.y + 3)
            default:
                return annotation
            }
            return Annotation(
                tool: .rectangle,
                start: opposite,
                end: endpoint,
                styleSize: annotation.styleSize,
                color: annotation.color
            )
        case .arrowStart:
            guard annotation.tool == .arrow else { return annotation }
            return Annotation(
                tool: .arrow,
                start: point,
                end: annotation.end,
                styleSize: annotation.styleSize,
                color: annotation.color
            )
        case .arrowEnd:
            guard annotation.tool == .arrow else { return annotation }
            return Annotation(
                tool: .arrow,
                start: annotation.start,
                end: point,
                styleSize: annotation.styleSize,
                color: annotation.color
            )
        case .textScale:
            guard annotation.tool == .text, let value = annotation.text else { return annotation }
            let originalBounds = annotationInteractionBounds(annotation)
            let originalDistance = max(
                1,
                hypot(
                    originalBounds.maxX - annotation.start.x,
                    originalBounds.maxY - annotation.start.y
                )
            )
            let requestedDistance = max(
                1,
                hypot(point.x - annotation.start.x, point.y - annotation.start.y)
            )
            var fontSize = min(
                max(annotation.resolvedStyleSize * requestedDistance / originalDistance, 12),
                72
            )
            let measured = value.size(withAttributes: [
                .font: annotationTextFont(size: fontSize),
            ])
            let availableWidth = max(1, selection.maxX - annotation.start.x)
            let availableHeight = max(1, selection.maxY - annotation.start.y)
            let fitScale = min(
                1,
                min(availableWidth / max(measured.width, 1), availableHeight / max(measured.height, 1))
            )
            fontSize = min(max((fontSize * fitScale).rounded(), 12), 72)
            return Annotation(
                tool: .text,
                start: annotation.start,
                end: annotation.end,
                text: value,
                styleSize: fontSize,
                color: annotation.color
            )
        }
    }

    private func toggleAnnotationTool(_ tool: AnnotationTool) {
        selectedTool = selectedTool == tool ? nil : tool
        currentAnnotation = nil
        hoveredAnnotationHit = nil
        toolSizeHintVisible = false
        toolSizeHintTool = nil
    }

    private func toolSize(for tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .rectangle:
            return rectangleLineWidth
        case .arrow:
            return arrowLineWidth
        case .text:
            return textFontSize
        }
    }

    private func setToolSize(_ size: CGFloat, for tool: AnnotationTool) {
        switch tool {
        case .rectangle, .arrow:
            rectangleLineWidth = size
            arrowLineWidth = size
        case .text:
            textFontSize = size
        }
    }

    private func updateTextEditor(_ editor: NSTextField, fontSize: CGFloat) {
        let font = annotationTextFont(size: fontSize)
        editor.font = font
        Self.updateTextEditorPlaceholder(
            editor,
            font: font,
            textColor: textEditorColor?.nsColor ?? annotationColor.nsColor
        )
        textEditorSize = fontSize
        guard let selection else { return }
        var frame = editor.frame
        frame.size.height = textEditorHeight(for: font)
        frame.size.width = textEditorWidth(
            for: editor.stringValue,
            font: font,
            maximum: selection.maxX - frame.minX
        )
        frame = CaptureGeometry.textEditorFrame(
            for: CGPoint(
                x: frame.minX,
                y: textEditorVerticalCenter ?? frame.midY
            ),
            size: frame.size,
            within: selection
        )
        editor.frame = frame
        textAnchor = textAnchor(for: frame, font: font)
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

    private func showToolSizeHint(for tool: AnnotationTool) {
        toolSizeHintGeneration += 1
        let generation = toolSizeHintGeneration
        toolSizeHintTool = tool
        toolSizeHintVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.toolSizeHintGeneration == generation else { return }
            self.toolSizeHintVisible = false
            self.toolSizeHintTool = nil
            self.needsDisplay = true
        }
    }

    private func annotationTextFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func textEditorHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 8
    }

    private func textEditorWidth(for value: String, font: NSFont, maximum: CGFloat) -> CGFloat {
        let displayedValue = value.isEmpty ? "输入文字" : value
        let measuredWidth = ceil((displayedValue as NSString).size(withAttributes: [.font: font]).width)
        return min(max(measuredWidth + 12, 48), max(0, maximum))
    }

    private func textAnchor(for editorFrame: CGRect, font: NSFont) -> CGPoint {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGPoint(
            x: editorFrame.minX + 4,
            y: editorFrame.midY - lineHeight / 2
        )
    }
}
