import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotRenderer {
    private static let maxPixels: CGFloat = 19_000_000
    private static let maxPayloadBytes = 24 * 1024 * 1024

    static func render(
        screenshot: CGImage,
        viewBounds: CGRect,
        selection: CGRect,
        annotations: [Annotation]
    ) throws -> UploadPayload {
        guard viewBounds.width > 0, viewBounds.height > 0,
              selection.width > 0, selection.height > 0 else {
            throw CaptureError.imageEncodingFailed
        }

        let scaleX = CGFloat(screenshot.width) / viewBounds.width
        let scaleY = CGFloat(screenshot.height) / viewBounds.height
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(screenshot.width),
            height: CGFloat(screenshot.height)
        )
        let pixelSelection = CGRect(
            x: floor(selection.minX * scaleX),
            y: floor(selection.minY * scaleY),
            width: ceil(selection.width * scaleX),
            height: ceil(selection.height * scaleY)
        ).intersection(imageBounds).integral
        guard pixelSelection.width > 0, pixelSelection.height > 0,
              let cropped = screenshot.cropping(to: pixelSelection) else {
            throw CaptureError.imageEncodingFailed
        }

        let sourcePixels = CGFloat(cropped.width) * CGFloat(cropped.height)
        let outputScale = min(1, sqrt(maxPixels / max(sourcePixels, 1)))
        let outputWidth = max(1, Int(CGFloat(cropped.width) * outputScale))
        let outputHeight = max(1, Int(CGFloat(cropped.height) * outputScale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CaptureError.imageEncodingFailed
        }

        context.interpolationQuality = .high
        let outputRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(outputWidth),
            height: CGFloat(outputHeight)
        )
        context.draw(cropped, in: outputRect)

        let annotationScaleX = CGFloat(outputWidth) / selection.width
        let annotationScaleY = CGFloat(outputHeight) / selection.height
        context.setStrokeColor(CGColor(red: 1, green: 0.12, blue: 0.1, alpha: 1))
        context.setLineWidth(max(3, 3 * min(annotationScaleX, annotationScaleY)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in annotations {
            draw(
                annotation,
                in: context,
                selection: selection,
                scaleX: annotationScaleX,
                scaleY: annotationScaleY,
                outputHeight: CGFloat(outputHeight)
            )
        }

        guard let image = context.makeImage() else {
            throw CaptureError.imageEncodingFailed
        }
        if let png = encode(image, type: .png, properties: [:]), png.count <= maxPayloadBytes {
            return UploadPayload(data: png, fileName: "screenshot.png", contentType: "image/png")
        }
        guard let jpeg = encode(
            image,
            type: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: 0.88]
        ), jpeg.count <= maxPayloadBytes else {
            throw CaptureError.imageEncodingFailed
        }
        return UploadPayload(data: jpeg, fileName: "screenshot.jpg", contentType: "image/jpeg")
    }

    private static func draw(
        _ annotation: Annotation,
        in context: CGContext,
        selection: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        outputHeight: CGFloat
    ) {
        func outputPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - selection.minX) * scaleX,
                y: outputHeight - (point.y - selection.minY) * scaleY
            )
        }

        switch annotation.tool {
        case .rectangle:
            context.stroke(CGRect.between(outputPoint(annotation.start), outputPoint(annotation.end)))
        case .arrow:
            let start = outputPoint(annotation.start)
            let end = outputPoint(annotation.end)
            let headLength = max(14, 14 * min(scaleX, scaleY))
            let angle = atan2(end.y - start.y, end.x - start.x)
            let spread = CGFloat.pi / 7
            let first = CGPoint(
                x: end.x - headLength * cos(angle - spread),
                y: end.y - headLength * sin(angle - spread)
            )
            let second = CGPoint(
                x: end.x - headLength * cos(angle + spread),
                y: end.y - headLength * sin(angle + spread)
            )
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.move(to: first)
            context.addLine(to: end)
            context.addLine(to: second)
            context.strokePath()
        }
    }

    private static func encode(
        _ image: CGImage,
        type: UTType,
        properties: [CFString: Any]
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
