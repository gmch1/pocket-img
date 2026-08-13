import CoreGraphics
import Foundation

enum AnnotationTool: Equatable, Sendable {
    case rectangle
    case arrow
    case text
}

struct Annotation: Equatable, Sendable {
    let tool: AnnotationTool
    let start: CGPoint
    let end: CGPoint
    let text: String?

    init(tool: AnnotationTool, start: CGPoint, end: CGPoint, text: String? = nil) {
        self.tool = tool
        self.start = start
        self.end = end
        self.text = text
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
