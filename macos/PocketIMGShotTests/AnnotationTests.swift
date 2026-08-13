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
            styleSize: 32
        )

        XCTAssertEqual(rectangle.resolvedStyleSize, 3)
        XCTAssertEqual(text.resolvedStyleSize, 32)
    }

    func testAnnotationStylePreferencesClampUnsafeValues() {
        let style = AnnotationStylePreferences(
            rectangleLineWidth: -4,
            arrowLineWidth: 30,
            textFontSize: 100
        ).normalized

        XCTAssertEqual(style.rectangleLineWidth, 1)
        XCTAssertEqual(style.arrowLineWidth, 12)
        XCTAssertEqual(style.textFontSize, 72)
    }
}
