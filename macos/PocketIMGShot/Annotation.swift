import CoreGraphics
import Foundation

enum AnnotationTool: Equatable, Sendable {
    case rectangle
    case arrow
    case text
}

enum AnnotationColor: String, CaseIterable, Codable, Equatable, Sendable {
    case red
    case yellow
    case green
    case blue
    case purple
    case white

    static let `default`: AnnotationColor = .red

    var components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        switch self {
        case .red:
            return (1, 0, 0, 1)
        case .yellow:
            return (1, 242.0 / 255.0, 0, 1)
        case .green:
            return (34.0 / 255.0, 177.0 / 255.0, 76.0 / 255.0, 1)
        case .blue:
            return (0, 162.0 / 255.0, 232.0 / 255.0, 1)
        case .purple:
            return (163.0 / 255.0, 73.0 / 255.0, 164.0 / 255.0, 1)
        case .white:
            return (1, 1, 1, 1)
        }
    }

    var cgColor: CGColor {
        let components = components
        return CGColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }
}

struct AnnotationStylePreferences: Codable, Equatable, Sendable {
    static let `default` = AnnotationStylePreferences(
        rectangleLineWidth: 2,
        arrowLineWidth: 2,
        textFontSize: 20,
        color: .default
    )

    let rectangleLineWidth: CGFloat
    let arrowLineWidth: CGFloat
    let textFontSize: CGFloat
    let color: AnnotationColor?

    init(
        rectangleLineWidth: CGFloat,
        arrowLineWidth: CGFloat,
        textFontSize: CGFloat,
        color: AnnotationColor = .default
    ) {
        self.rectangleLineWidth = rectangleLineWidth
        self.arrowLineWidth = arrowLineWidth
        self.textFontSize = textFontSize
        self.color = color
    }

    var resolvedColor: AnnotationColor {
        color ?? .default
    }

    var lineWidth: CGFloat {
        let rectangle = min(max(rectangleLineWidth, 1), 12)
        let arrow = min(max(arrowLineWidth, 1), 12)
        guard rectangle != arrow else { return rectangle }
        let defaultWidth = Self.default.rectangleLineWidth
        let rectangleDistance = abs(rectangle - defaultWidth)
        let arrowDistance = abs(arrow - defaultWidth)
        return arrowDistance > rectangleDistance ? arrow : rectangle
    }

    var normalized: AnnotationStylePreferences {
        let lineWidth = lineWidth
        return AnnotationStylePreferences(
            rectangleLineWidth: lineWidth,
            arrowLineWidth: lineWidth,
            textFontSize: min(max(textFontSize, 12), 72),
            color: resolvedColor
        )
    }
}

struct Annotation: Equatable, Sendable {
    let tool: AnnotationTool
    let start: CGPoint
    let end: CGPoint
    let text: String?
    let styleSize: CGFloat?
    let color: AnnotationColor

    init(
        tool: AnnotationTool,
        start: CGPoint,
        end: CGPoint,
        text: String? = nil,
        styleSize: CGFloat? = nil,
        color: AnnotationColor = .default
    ) {
        self.tool = tool
        self.start = start
        self.end = end
        self.text = text
        self.styleSize = styleSize
        self.color = color
    }

    var resolvedStyleSize: CGFloat {
        styleSize ?? (tool == .text ? 20 : 2)
    }

    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    var isMeaningful: Bool {
        switch tool {
        case .rectangle:
            return rect.width >= 3 && rect.height >= 3
        case .arrow:
            return hypot(end.x - start.x, end.y - start.y) >= 6
        case .text:
            return !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    func translatedBy(x: CGFloat, y: CGFloat) -> Annotation {
        Annotation(
            tool: tool,
            start: CGPoint(x: start.x + x, y: start.y + y),
            end: CGPoint(x: end.x + x, y: end.y + y),
            text: text,
            styleSize: styleSize,
            color: color
        )
    }

    func withStyleSize(_ styleSize: CGFloat) -> Annotation {
        Annotation(
            tool: tool,
            start: start,
            end: end,
            text: text,
            styleSize: styleSize,
            color: color
        )
    }
}

struct UploadPayload: Sendable {
    let data: Data
    let fileName: String
    let contentType: String
    let displaySize: CGSize
    let placementFrame: CGRect?

    init(
        data: Data,
        fileName: String,
        contentType: String,
        displaySize: CGSize,
        placementFrame: CGRect? = nil
    ) {
        self.data = data
        self.fileName = fileName
        self.contentType = contentType
        self.displaySize = displaySize
        self.placementFrame = placementFrame
    }

    func placed(in frame: CGRect) -> UploadPayload {
        UploadPayload(
            data: data,
            fileName: fileName,
            contentType: contentType,
            displaySize: displaySize,
            placementFrame: frame
        )
    }
}

enum SelectionResizeHandle: CaseIterable, Hashable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

enum CaptureGeometry {
    static func rectangleAnnotation(
        _ rect: CGRect,
        contains point: CGPoint,
        tolerance: CGFloat,
        includesInterior: Bool
    ) -> Bool {
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else {
            return false
        }
        if includesInterior { return true }
        guard rect.width > tolerance * 2, rect.height > tolerance * 2 else {
            return true
        }
        return !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
    }

    static func textEditorFrame(
        for clickPoint: CGPoint,
        size: CGSize,
        within bounds: CGRect
    ) -> CGRect {
        let maxOriginX = max(bounds.minX, bounds.maxX - size.width)
        let maxOriginY = max(bounds.minY, bounds.maxY - size.height)
        return CGRect(
            x: min(max(clickPoint.x, bounds.minX), maxOriginX),
            y: min(
                max(clickPoint.y - size.height / 2, bounds.minY),
                maxOriginY
            ),
            width: size.width,
            height: size.height
        )
    }

    static func capturePixelSize(
        displayPointSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGSize {
        CGSize(
            width: max(1, (displayPointSize.width * backingScaleFactor).rounded()),
            height: max(1, (displayPointSize.height * backingScaleFactor).rounded())
        )
    }

    static func screenFrame(for selection: CGRect, in captureWindowFrame: CGRect) -> CGRect {
        CGRect(
            x: captureWindowFrame.minX + selection.minX,
            y: captureWindowFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    static func screenLocalFrame(for frame: CGRect, on screenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - screenFrame.minX,
            y: frame.minY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    static func movedSelection(
        _ selection: CGRect,
        from dragStart: CGPoint,
        to point: CGPoint,
        within bounds: CGRect
    ) -> CGRect {
        let offset = clampedMovementOffset(
            moving: selection,
            from: dragStart,
            to: point,
            within: bounds
        )
        return selection.offsetBy(dx: offset.x, dy: offset.y)
    }

    static func resizedSelection(
        _ selection: CGRect,
        using handle: SelectionResizeHandle,
        to point: CGPoint,
        within bounds: CGRect,
        minimumSize: CGFloat = 8
    ) -> CGRect {
        let minimumWidth = min(max(1, minimumSize), bounds.width)
        let minimumHeight = min(max(1, minimumSize), bounds.height)
        let point = CGPoint(
            x: min(max(point.x.rounded(), bounds.minX), bounds.maxX),
            y: min(max(point.y.rounded(), bounds.minY), bounds.maxY)
        )
        var minX = selection.minX
        var minY = selection.minY
        var maxX = selection.maxX
        var maxY = selection.maxY

        switch handle {
        case .topLeft:
            minX = min(point.x, maxX - minimumWidth)
            minY = min(point.y, maxY - minimumHeight)
        case .top:
            minY = min(point.y, maxY - minimumHeight)
        case .topRight:
            maxX = max(point.x, minX + minimumWidth)
            minY = min(point.y, maxY - minimumHeight)
        case .right:
            maxX = max(point.x, minX + minimumWidth)
        case .bottomRight:
            maxX = max(point.x, minX + minimumWidth)
            maxY = max(point.y, minY + minimumHeight)
        case .bottom:
            maxY = max(point.y, minY + minimumHeight)
        case .bottomLeft:
            minX = min(point.x, maxX - minimumWidth)
            maxY = max(point.y, minY + minimumHeight)
        case .left:
            minX = min(point.x, maxX - minimumWidth)
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(bounds)
    }

    static func clampedMovementOffset(
        moving frame: CGRect,
        from dragStart: CGPoint,
        to point: CGPoint,
        within bounds: CGRect
    ) -> CGPoint {
        let requestedX = (point.x - dragStart.x).rounded()
        let requestedY = (point.y - dragStart.y).rounded()
        let offsetX = min(
            max(requestedX, bounds.minX - frame.minX),
            bounds.maxX - frame.maxX
        )
        let offsetY = min(
            max(requestedY, bounds.minY - frame.minY),
            bounds.maxY - frame.maxY
        )
        return CGPoint(x: offsetX, y: offsetY)
    }
}

extension CGRect {
    static func between(_ first: CGPoint, _ second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}
