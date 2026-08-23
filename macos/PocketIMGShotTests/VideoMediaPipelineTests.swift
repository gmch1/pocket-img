import Foundation
import XCTest
@testable import PocketIMGShot

final class VideoMediaPipelineTests: XCTestCase {
    func testTrimRangeClampsToMovieDuration() throws {
        let normalized = try XCTUnwrap(
            VideoTrimRange(start: -2, end: 12).normalized(forDuration: 10)
        )

        XCTAssertEqual(normalized, VideoTrimRange(start: 0, end: 10))
        XCTAssertEqual(normalized.duration, 10, accuracy: 0.000_001)
    }

    func testTrimRangeRejectsInvalidOrTooShortValues() {
        XCTAssertNil(VideoTrimRange(start: 4, end: 2).normalized(forDuration: 10))
        XCTAssertNil(VideoTrimRange(start: .nan, end: 2).normalized(forDuration: 10))
        XCTAssertNil(VideoTrimRange(start: 1, end: 1.05).normalized(forDuration: 10))
        XCTAssertNil(VideoTrimRange(start: 1, end: 2).normalized(forDuration: .infinity))
    }

    func testTrimGeometryMapsTimeAndTimelineCoordinates() {
        let track = CGRect(x: 100, y: 0, width: 500, height: 80)

        XCTAssertEqual(
            VideoTrimGeometry.x(forTime: 5, duration: 10, trackRect: track),
            350,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            VideoTrimGeometry.time(forX: 350, duration: 10, trackRect: track),
            5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(VideoTrimGeometry.time(forX: 50, duration: 10, trackRect: track), 0)
        XCTAssertEqual(VideoTrimGeometry.time(forX: 700, duration: 10, trackRect: track), 10)
    }

    func testTrimGeometryKeepsHandlesSeparatedByMinimumDuration() {
        let current = VideoTrimRange(start: 2, end: 8)
        let movedStart = VideoTrimGeometry.clampedRange(
            current: current,
            changing: .start,
            proposedTime: 9,
            duration: 10,
            minimumDuration: 0.5,
            snap: 0.1
        )
        let movedEnd = VideoTrimGeometry.clampedRange(
            current: current,
            changing: .end,
            proposedTime: 1,
            duration: 10,
            minimumDuration: 0.5,
            snap: 0.1
        )

        XCTAssertEqual(movedStart.start, 7.5, accuracy: 0.000_001)
        XCTAssertEqual(movedStart.end, 8, accuracy: 0.000_001)
        XCTAssertEqual(movedEnd.start, 2, accuracy: 0.000_001)
        XCTAssertEqual(movedEnd.end, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(
            VideoTrimGeometry.clampedRange(
                current: current,
                changing: .start,
                proposedTime: .nan,
                duration: 10,
                minimumDuration: 0.5,
                snap: 0.1
            ),
            current
        )

        let snapped = VideoTrimGeometry.clampedRange(
            current: current,
            changing: .start,
            proposedTime: 2.26,
            duration: 10,
            minimumDuration: 0.5,
            snap: 0.1
        )
        XCTAssertEqual(snapped.start, 2.3, accuracy: 0.000_001)
    }
}
