import XCTest
@testable import PocketIMGShot

final class AnnotationTests: XCTestCase {
    func testRectangleNormalizesDragDirection() {
        let value = Annotation(
            tool: .rectangle,
            start: CGPoint(x: 80, y: 60),
            end: CGPoint(x: 20, y: 10)
        )

        XCTAssertEqual(value.rect, CGRect(x: 20, y: 10, width: 60, height: 50))
        XCTAssertTrue(value.isMeaningful)
    }

    func testTinyAnnotationsAreIgnored() {
        XCTAssertFalse(Annotation(
            tool: .rectangle,
            start: CGPoint(x: 1, y: 1),
            end: CGPoint(x: 2, y: 2)
        ).isMeaningful)
        XCTAssertFalse(Annotation(
            tool: .arrow,
            start: CGPoint(x: 1, y: 1),
            end: CGPoint(x: 3, y: 3)
        ).isMeaningful)
        XCTAssertFalse(Annotation(
            tool: .text,
            start: CGPoint(x: 1, y: 1),
            end: CGPoint(x: 1, y: 1),
            text: "  "
        ).isMeaningful)
        XCTAssertTrue(Annotation(
            tool: .text,
            start: CGPoint(x: 1, y: 1),
            end: CGPoint(x: 1, y: 1),
            text: "说明"
        ).isMeaningful)
    }

    func testConvertsFlippedSelectionToScreenCoordinates() {
        let screenFrame = CaptureGeometry.screenFrame(
            for: CGRect(x: 100, y: 50, width: 500, height: 300),
            in: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(screenFrame, CGRect(x: -1820, y: 730, width: 500, height: 300))
    }

    func testCapturePixelSizeUsesRetinaBackingScale() {
        XCTAssertEqual(
            CaptureGeometry.capturePixelSize(
                displayPointSize: CGSize(width: 1512, height: 982),
                backingScaleFactor: 2
            ),
            CGSize(width: 3024, height: 1964)
        )
    }

    func testAnnotationStyleSizesHaveToolDefaultsAndCanBeCustomized() {
        let rectangle = Annotation(
            tool: .rectangle,
            start: .zero,
            end: CGPoint(x: 20, y: 20)
        )
        let text = Annotation(
            tool: .text,
            start: .zero,
            end: .zero,
            text: "说明",
            styleSize: 32,
            color: .blue
        )

        XCTAssertEqual(rectangle.resolvedStyleSize, 3)
        XCTAssertEqual(rectangle.color, .red)
        XCTAssertEqual(text.resolvedStyleSize, 32)
        XCTAssertEqual(text.color, .blue)
    }

    func testAnnotationStylePreferencesClampUnsafeValues() {
        let style = AnnotationStylePreferences(
            rectangleLineWidth: -4,
            arrowLineWidth: 30,
            textFontSize: 100,
            color: .purple
        ).normalized

        XCTAssertEqual(style.rectangleLineWidth, 1)
        XCTAssertEqual(style.arrowLineWidth, 12)
        XCTAssertEqual(style.textFontSize, 72)
        XCTAssertEqual(style.resolvedColor, .purple)
    }

    func testAnnotationStyleDecodesLegacyJSONWithoutColor() throws {
        let legacy = """
        {
          "rectangleLineWidth": 4,
          "arrowLineWidth": 5,
          "textFontSize": 24
        }
        """

        let style = try JSONDecoder().decode(
            AnnotationStylePreferences.self,
            from: try XCTUnwrap(legacy.data(using: .utf8))
        )

        XCTAssertEqual(style.resolvedColor, .red)
        XCTAssertEqual(style.normalized.color, .red)
    }

    @MainActor
    func testTextFieldCellCentersPlaceholderAndEditorRect() {
        let cell = VerticallyCenteredTextFieldCell(textCell: "输入文字")
        cell.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 32)

        let textRect = cell.drawingRect(forBounds: bounds)

        XCTAssertEqual(textRect.midY, bounds.midY, accuracy: 0.01)
        XCTAssertLessThan(textRect.height, bounds.height)
        XCTAssertGreaterThan(textRect.minX, bounds.minX)
        XCTAssertLessThan(textRect.maxX, bounds.maxX)
    }
}
