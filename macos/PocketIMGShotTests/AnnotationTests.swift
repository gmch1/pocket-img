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
    }
}
