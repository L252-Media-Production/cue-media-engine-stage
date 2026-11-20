import CoreGraphics
import CoreText
import Foundation
import Metal

/// One centred line of text.
public struct TextLine: Equatable {
    public var text: String
    public var fontSize: CGFloat
    /// Vertical centre of the line, measured from the top of the frame.
    public var centerYFromTop: CGFloat

    public init(text: String, fontSize: CGFloat, centerYFromTop: CGFloat) {
        self.text = text
        self.fontSize = fontSize
        self.centerYFromTop = centerYFromTop
    }
}

/// A full-frame transparent layer that holds centred text. Redrawn only when the lines change.
/// Call `update` from one thread only.
public final class TextLayer {
    public let width: Int
    public let height: Int
    public let layer: RetainedTexture

    private let context: CGContext
    private let texture: MTLTexture
    private var lastLines: [TextLine] = []

    public init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else {
            throw CompositorError.textContextFailed
        }
        self.context = context

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw CompositorError.textContextFailed
        }
        self.texture = texture
        self.layer = RetainedTexture(texture: texture)
        _ = update([])
    }

    /// Redraw if the lines changed. Returns true when the texture was updated.
    @discardableResult
    public func update(_ lines: [TextLine]) -> Bool {
        if lines == lastLines && !lastLines.isEmpty { return false }
        lastLines = lines

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 10,
                          color: CGColor(gray: 0, alpha: 0.85))

        for line in lines {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, line.fontSize, nil)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]
            let attributed = CFAttributedStringCreate(nil, line.text as CFString, attributes as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let textWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let x = (CGFloat(width) - CGFloat(textWidth)) / 2
            let baselineY = CGFloat(height) - line.centerYFromTop - line.fontSize * 0.35
            context.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(ctLine, context)
        }

        if let data = context.data {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: data, bytesPerRow: context.bytesPerRow)
        }
        return true
    }
}
