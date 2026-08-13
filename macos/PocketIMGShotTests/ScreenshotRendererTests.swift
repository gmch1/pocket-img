import CoreGraphics
import ImageIO
import XCTest
@testable import PocketIMGShot

final class ScreenshotRendererTests: XCTestCase {
    func testTextAnnotationKeepsBrightRedWithoutDarkOutline() throws {
        let source = try makeImage(
            width: 320,
            height: 120,
            fillColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let payload = try ScreenshotRenderer.render(
            screenshot: source,
            viewBounds: CGRect(x: 0, y: 0, width: 320, height: 120),
            selection: CGRect(x: 0, y: 0, width: 320, height: 120),
            annotations: [
                Annotation(
                    tool: .text,
                    start: CGPoint(x: 20, y: 20),
                    end: CGPoint(x: 20, y: 20),
                    text: "RED",
                    styleSize: 44,
                    color: .red
                ),
            ]
        )
        let encodedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(payload.data as CFData, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encodedSource, 0, nil))
        let pixels = try rgbaPixels(from: image)
        let annotationPixels = pixels.filter { pixel in
            pixel.green < 250 || pixel.blue < 250
        }

        XCTAssertFalse(annotationPixels.isEmpty)
        XCTAssertGreaterThanOrEqual(annotationPixels.map { $0.red }.min() ?? 0, 245)
        XCTAssertTrue(annotationPixels.contains { pixel in
            Int(pixel.red) - Int(pixel.green) >= 80
                && Int(pixel.red) - Int(pixel.blue) >= 80
        })
    }

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

    private func makeImage(
        width: Int,
        height: Int,
        fillColor: CGColor = CGColor(red: 0.2, green: 0.35, blue: 0.55, alpha: 1)
    ) throws -> CGImage {
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
        context.setFillColor(fillColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaPixels(from image: CGImage) throws -> [(red: UInt8, green: UInt8, blue: UInt8)] {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        XCTAssertTrue(rendered)
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            (red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2])
        }
    }
}
