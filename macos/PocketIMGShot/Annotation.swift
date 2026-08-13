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
            return (1, 0.12, 0.10, 1)
        case .yellow:
            return (1, 0.82, 0.12, 1)
        case .green:
            return (0.20, 0.82, 0.38, 1)
        case .blue:
            return (0.18, 0.55, 1, 1)
        case .purple:
            return (0.68, 0.38, 1, 1)
        case .white:
            return (0.96, 0.96, 0.98, 1)
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
        rectangleLineWidth: 3,
        arrowLineWidth: 3,
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

    var normalized: AnnotationStylePreferences {
        AnnotationStylePreferences(
            rectangleLineWidth: min(max(rectangleLineWidth, 1), 12),
            arrowLineWidth: min(max(arrowLineWidth, 1), 12),
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
        styleSize ?? (tool == .text ? 20 : 3)
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

enum CaptureGeometry {
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
