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

    func testMovesSelectionWithoutChangingSizeAndClampsToScreen() {
        let original = CGRect(x: 100, y: 80, width: 300, height: 200)

        XCTAssertEqual(
            CaptureGeometry.movedSelection(
                original,
                from: CGPoint(x: 150, y: 120),
                to: CGPoint(x: 210, y: 160),
                within: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
            CGRect(x: 160, y: 120, width: 300, height: 200)
        )
        XCTAssertEqual(
            CaptureGeometry.movedSelection(
                original,
                from: CGPoint(x: 150, y: 120),
                to: CGPoint(x: -500, y: -500),
                within: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
            CGRect(x: 0, y: 0, width: 300, height: 200)
        )
    }

    func testAnnotationsFollowMovedSelection() {
        let annotation = Annotation(
            tool: .text,
            start: CGPoint(x: 120, y: 90),
            end: CGPoint(x: 120, y: 90),
            text: "说明",
            styleSize: 20,
            color: .red
        )

        let moved = annotation.translatedBy(x: 40, y: -15)

        XCTAssertEqual(moved.start, CGPoint(x: 160, y: 75))
        XCTAssertEqual(moved.end, CGPoint(x: 160, y: 75))
        XCTAssertEqual(moved.text, annotation.text)
        XCTAssertEqual(moved.styleSize, annotation.styleSize)
        XCTAssertEqual(moved.color, annotation.color)
    }

    func testAnnotationStyleSizeCanChangeWithoutChangingItsContentOrPosition() {
        let annotation = Annotation(
            tool: .text,
            start: CGPoint(x: 120, y: 90),
            end: CGPoint(x: 120, y: 90),
            text: "说明",
            styleSize: 20,
            color: .blue
        )

        let resized = annotation.withStyleSize(32)

        XCTAssertEqual(resized.start, annotation.start)
        XCTAssertEqual(resized.end, annotation.end)
        XCTAssertEqual(resized.text, annotation.text)
        XCTAssertEqual(resized.resolvedStyleSize, 32)
        XCTAssertEqual(resized.color, annotation.color)
    }

    func testClampsAnnotationMovementToSelectionBounds() {
        let offset = CaptureGeometry.clampedMovementOffset(
            moving: CGRect(x: 180, y: 120, width: 60, height: 40),
            from: CGPoint(x: 200, y: 140),
            to: CGPoint(x: 500, y: 500),
            within: CGRect(x: 100, y: 80, width: 200, height: 120)
        )

        XCTAssertEqual(offset, CGPoint(x: 60, y: 40))
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

        XCTAssertEqual(rectangle.resolvedStyleSize, 2)
        XCTAssertEqual(rectangle.color, .red)
        XCTAssertEqual(text.resolvedStyleSize, 32)
        XCTAssertEqual(text.color, .blue)
        XCTAssertEqual(AnnotationStylePreferences.default.rectangleLineWidth, 2)
        XCTAssertEqual(AnnotationStylePreferences.default.arrowLineWidth, 2)
        XCTAssertEqual(AnnotationColor.red.components.red, 1)
        XCTAssertEqual(AnnotationColor.red.components.green, 0)
        XCTAssertEqual(AnnotationColor.red.components.blue, 0)
        XCTAssertEqual(AnnotationColor.yellow.components.green, 242.0 / 255.0)
        XCTAssertEqual(AnnotationColor.green.components.red, 34.0 / 255.0)
        XCTAssertEqual(AnnotationColor.blue.components.green, 162.0 / 255.0)
        XCTAssertEqual(AnnotationColor.purple.components.red, 163.0 / 255.0)
        XCTAssertEqual(AnnotationColor.white.components.blue, 1)
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
    func testTextFieldCellCentersPlaceholderAndAcceptsInput() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 32)
        let expectedColor = NSColor(
            srgbRed: 1,
            green: 0,
            blue: 0,
            alpha: 1
        )
        let field = CaptureOverlayView.makeEditableTextField(
            frame: bounds,
            textColor: expectedColor
        )
        let cell = try XCTUnwrap(field.cell as? VerticallyCenteredTextFieldCell)
        cell.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        field.placeholderString = "输入文字"

        let textRect = cell.drawingRect(forBounds: bounds)

        XCTAssertEqual(textRect.midY, bounds.midY, accuracy: 0.01)
        XCTAssertLessThan(textRect.height, bounds.height)
        XCTAssertGreaterThan(textRect.minX, bounds.minX)
        XCTAssertLessThan(textRect.maxX, bounds.maxX)
        XCTAssertTrue(cell.isEditable)
        XCTAssertTrue(cell.isSelectable)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.isSelectable)
        XCTAssertTrue(field.acceptsFirstResponder)
        XCTAssertEqual(field.textColor, expectedColor)
        field.stringValue = "测试输入"
        XCTAssertEqual(field.stringValue, "测试输入")
    }
}
