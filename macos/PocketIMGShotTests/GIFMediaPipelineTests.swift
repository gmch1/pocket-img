import Foundation
import XCTest
@testable import PocketIMGShot

final class GIFMediaPipelineTests: XCTestCase {
    func testTrimRangeClampsToMovieDuration() throws {
        let normalized = try XCTUnwrap(
            GIFTrimRange(start: -2, end: 12).normalized(forDuration: 10)
        )

        XCTAssertEqual(normalized, GIFTrimRange(start: 0, end: 10))
        XCTAssertEqual(normalized.duration, 10, accuracy: 0.000_001)
    }

    func testTrimRangeRejectsInvalidOrTooShortValues() {
        XCTAssertNil(GIFTrimRange(start: 4, end: 2).normalized(forDuration: 10))
        XCTAssertNil(GIFTrimRange(start: .nan, end: 2).normalized(forDuration: 10))
        XCTAssertNil(GIFTrimRange(start: 1, end: 1.05).normalized(forDuration: 10))
        XCTAssertNil(GIFTrimRange(start: 1, end: 2).normalized(forDuration: .infinity))
    }

    func testFrameScheduleSamplesOnlyInsideTrimRange() throws {
        let schedule = try XCTUnwrap(GIFFrameSchedule(
            trimRange: GIFTrimRange(start: 2, end: 4.5),
            assetDuration: 10,
            frameRate: 10
        ))

        XCTAssertEqual(schedule.frameCount, 25)
        XCTAssertEqual(try XCTUnwrap(schedule.sampleTime(forFrame: 0)), 2, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(schedule.sampleTime(forFrame: 24)), 4.4, accuracy: 0.000_001)
        XCTAssertNil(schedule.sampleTime(forFrame: 25))
        for index in 0..<schedule.frameCount {
            let sample = try XCTUnwrap(schedule.sampleTime(forFrame: index))
            XCTAssertGreaterThanOrEqual(sample, schedule.range.start)
            XCTAssertLessThan(sample, schedule.range.end)
        }
    }

    func testFrameScheduleShortensOnlyPartialFinalFrame() throws {
        let schedule = try XCTUnwrap(GIFFrameSchedule(
            trimRange: GIFTrimRange(start: 2, end: 4.45),
            assetDuration: 10,
            frameRate: 10
        ))

        XCTAssertEqual(schedule.frameCount, 25)
        XCTAssertEqual(try XCTUnwrap(schedule.frameDelay(forFrame: 0)), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(schedule.frameDelay(forFrame: 24)), 0.05, accuracy: 0.000_001)
        XCTAssertEqual(schedule.range.duration, 2.45, accuracy: 0.000_001)
    }

    func testFrameScheduleDoesNotAddFrameForFloatingPointULP() throws {
        let schedule = try XCTUnwrap(GIFFrameSchedule(
            trimRange: GIFTrimRange(start: 0, end: 0.1 + 0.2),
            assetDuration: 1,
            frameRate: 10
        ))

        XCTAssertEqual(schedule.frameCount, 3)
        XCTAssertEqual(try XCTUnwrap(schedule.sampleTime(forFrame: 2)), 0.2, accuracy: 0.000_001)
        XCTAssertNil(schedule.sampleTime(forFrame: 3))
    }

    func testTrimGeometryMapsTimeAndTimelineCoordinates() {
        let track = CGRect(x: 100, y: 0, width: 500, height: 80)

        XCTAssertEqual(
            GIFTrimGeometry.x(forTime: 5, duration: 10, trackRect: track),
            350,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GIFTrimGeometry.time(forX: 350, duration: 10, trackRect: track),
            5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(GIFTrimGeometry.time(forX: 50, duration: 10, trackRect: track), 0)
        XCTAssertEqual(GIFTrimGeometry.time(forX: 700, duration: 10, trackRect: track), 10)
    }

    func testTrimGeometryKeepsHandlesSeparatedByMinimumDuration() {
        let current = GIFTrimRange(start: 2, end: 8)
        let movedStart = GIFTrimGeometry.clampedRange(
            current: current,
            changing: .start,
            proposedTime: 9,
            duration: 10,
            minimumDuration: 0.5,
            snap: 0.1
        )
        let movedEnd = GIFTrimGeometry.clampedRange(
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
            GIFTrimGeometry.clampedRange(
                current: current,
                changing: .start,
                proposedTime: .nan,
                duration: 10,
                minimumDuration: 0.5,
                snap: 0.1
            ),
            current
        )

        let snapped = GIFTrimGeometry.clampedRange(
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
