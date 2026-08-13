import CoreGraphics
import Foundation

enum AnnotationTool: Equatable, Sendable {
    case rectangle
    case arrow
    case text
}

struct AnnotationStylePreferences: Codable, Equatable, Sendable {
    static let `default` = AnnotationStylePreferences(
        rectangleLineWidth: 3,
        arrowLineWidth: 3,
        textFontSize: 20
    )

    let rectangleLineWidth: CGFloat
    let arrowLineWidth: CGFloat
    let textFontSize: CGFloat

    var normalized: AnnotationStylePreferences {
        AnnotationStylePreferences(
            rectangleLineWidth: min(max(rectangleLineWidth, 1), 12),
            arrowLineWidth: min(max(arrowLineWidth, 1), 12),
            textFontSize: min(max(textFontSize, 12), 72)
        )
    }
}

struct Annotation: Equatable, Sendable {
    let tool: AnnotationTool
    let start: CGPoint
    let end: CGPoint
    let text: String?
    let styleSize: CGFloat?

    init(
        tool: AnnotationTool,
        start: CGPoint,
        end: CGPoint,
        text: String? = nil,
        styleSize: CGFloat? = nil
    ) {
        self.tool = tool
        self.start = start
        self.end = end
        self.text = text
        self.styleSize = styleSize
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
