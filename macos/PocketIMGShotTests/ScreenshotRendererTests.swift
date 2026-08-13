import CoreGraphics
import ImageIO
import XCTest
@testable import PocketIMGShot

final class ScreenshotRendererTests: XCTestCase {
    func testRendersLargeRetinaSelectionWithAnnotations() throws {
        let source = try makeImage(width: 5120, height: 2880)
        let selection = CGRect(x: 100, y: 100, width: 2360, height: 1240)
        let payload = try ScreenshotRenderer.render(
            screenshot: source,
            viewBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            selection: selection,
            annotations: [
                Annotation(
                    tool: .rectangle,
                    start: CGPoint(x: 180, y: 180),
                    end: CGPoint(x: 900, y: 700)
                ),
                Annotation(
                    tool: .arrow,
                    start: CGPoint(x: 400, y: 900),
                    end: CGPoint(x: 1500, y: 300)
                ),
                Annotation(
                    tool: .text,
                    start: CGPoint(x: 600, y: 280),
                    end: CGPoint(x: 600, y: 280),
                    text: "截图说明"
                ),
            ]
        )

        XCTAssertEqual(payload.contentType, "image/png")
        XCTAssertFalse(payload.data.isEmpty)
        XCTAssertEqual(payload.displaySize, selection.size)
        let placement = CGRect(x: 120, y: 240, width: selection.width, height: selection.height)
        XCTAssertEqual(payload.placed(in: placement).placementFrame, placement)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(payload.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)) as NSDictionary
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 4720)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2480)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return try XCTUnwrap(context.makeImage())
    }
}
