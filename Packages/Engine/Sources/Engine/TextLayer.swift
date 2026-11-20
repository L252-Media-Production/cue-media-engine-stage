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
///
/// Drawing happens on a background queue into a hidden back buffer, then the layer swaps to it, so
/// a change of text never stalls the render loop. `update` and `layer` may be called from the render
/// thread every frame.
public final class TextLayer {
    public let width: Int
    public let height: Int

    private struct Buffer {
        let context: CGContext
        let texture: MTLTexture
        let retained: RetainedTexture
    }

    private let buffers: [Buffer]
    private let drawQueue = DispatchQueue(label: "stage.engine.text", qos: .userInitiated)
    private let lock = NSLock()
    private var frontIndex = 0
    private var requested: [TextLine] = []   // newest lines asked for
    private var drawn: [TextLine] = []       // lines in the front buffer
    private var drawing = false

    /// The texture to composite. Changes only when a background redraw has finished.
    public var layer: RetainedTexture {
        lock.lock()
        defer { lock.unlock() }
        return buffers[frontIndex].retained
    }

    public init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height

        var made: [Buffer] = []
        for _ in 0..<2 {
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else {
                throw CompositorError.textContextFailed
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CompositorError.textContextFailed
            }
            made.append(Buffer(context: context, texture: texture, retained: RetainedTexture(texture: texture)))
        }
        buffers = made
        // Start with an empty (transparent) front buffer.
        let empty = made[0]
        empty.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                              withBytes: empty.context.data!, bytesPerRow: empty.context.bytesPerRow)
    }

    /// Ask for these lines to be shown. Returns immediately; the layer switches when drawing is done.
    @discardableResult
    public func update(_ lines: [TextLine]) -> Bool {
        lock.lock()
        if lines == requested {
            lock.unlock()
            return false
        }
        requested = lines
        let shouldStart = !drawing
        if shouldStart { drawing = true }
        lock.unlock()

        if shouldStart { drawQueue.async { [self] in drawLoop() } }
        return true
    }

    private func drawLoop() {
        while true {
            lock.lock()
            let lines = requested
            let back = 1 - frontIndex
            if lines == drawn {
                drawing = false
                lock.unlock()
                return
            }
            lock.unlock()

            render(lines, into: buffers[back])

            lock.lock()
            frontIndex = back
            drawn = lines
            lock.unlock()
        }
    }

    private func render(_ lines: [TextLine], into buffer: Buffer) {
        let context = buffer.context
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
            buffer.texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                   withBytes: data, bytesPerRow: context.bytesPerRow)
        }
    }
}
