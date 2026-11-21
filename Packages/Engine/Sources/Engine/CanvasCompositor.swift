import CoreVideo
import Foundation
import Metal

/// A rectangle in pixels: a screen's place on the canvas, or a layer's place inside a composition.
public struct ScreenRegion: Equatable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height) at (\(x), \(y))" }
}

/// How a layer's picture fills its rectangle.
public enum LayerFit {
    /// Stretch to the rectangle (aspect ratio ignored).
    case stretch
    /// Fill the rectangle and crop what does not fit.
    case cover
    /// Fit inside the rectangle and leave the rest empty.
    case contain
}

/// One layer ready to draw this frame.
public struct CanvasLayerDraw {
    /// The picture, or nil for the animated test pattern (master composition only).
    public var texture: RetainedTexture?
    public var contentWidth: Int
    public var contentHeight: Int
    /// Where the layer goes in its composition; nil fills the whole composition.
    public var rect: ScreenRegion?
    public var opacity: Float
    public var fit: LayerFit

    public init(texture: RetainedTexture?, contentWidth: Int, contentHeight: Int,
                rect: ScreenRegion? = nil, opacity: Float = 1, fit: LayerFit = .stretch) {
        self.texture = texture
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.rect = rect
        self.opacity = opacity
        self.fit = fit
    }

    public static func pattern(opacity: Float = 1) -> CanvasLayerDraw {
        CanvasLayerDraw(texture: nil, contentWidth: 1, contentHeight: 1, opacity: opacity)
    }
}

/// What to draw for one screen this frame: whether the master shows through, and the screen's own layers.
public struct CanvasScreenDraw {
    public var showMaster: Bool
    /// Bottom to top.
    public var layers: [CanvasLayerDraw]

    public init(showMaster: Bool = true, layers: [CanvasLayerDraw] = []) {
        self.showMaster = showMaster
        self.layers = layers
    }
}

/// Renders the master composition on one large canvas, then one composition per screen on top of its
/// slice of the master, and packs each screen as a 1080p 4:2:2 frame for an SDI output.
///
/// - The **master** spans the whole canvas (for example 6000x1920).
/// - Each **screen** has its own composition at the size of its rectangle. It starts from the master
///   slice underneath it (unless `showMaster` is off, which leaves it transparent, that is black on SDI)
///   and draws the screen's own layers on top.
/// - A screen whose rectangle is not 1920x1080 is scaled to the output.
///
/// Call `render` from one thread only.
public final class CanvasCompositor {
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let screens: [ScreenRegion]
    public let outputWidth: Int
    public let outputHeight: Int
    public let device: MTLDevice

    private let queue: MTLCommandQueue
    private let canvasTexture: MTLTexture
    private let screenTextures: [MTLTexture]
    private let layerPipeline: MTLRenderPipelineState
    private let patternPipeline: MTLRenderPipelineState
    private let packPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let packedPool: CVPixelBufferPool
    private var renderCount = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut canvas_vertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
        VOut o;
        o.position = float4(pos[vid], 0.0, 1.0);
        o.uv = uvs[vid];
        return o;
    }

    // One layer (premultiplied alpha). p: uv scale x, y, uv offset x, y, opacity.
    fragment float4 layer_fragment(VOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   constant float *p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv * float2(p[0], p[1]) + float2(p[2], p[3]);
        return tex.sample(s, uv) * p[4];
    }

    static float4 over(float4 dst, float3 rgb, float a) {
        return float4(rgb * a, a) + dst * (1.0 - a);   // premultiplied source-over
    }

    static float3 screenColor(uint i) {
        switch (i % 6) {
            case 0: return float3(1.0, 0.25, 0.25);
            case 1: return float3(0.25, 1.0, 0.35);
            case 2: return float3(0.3, 0.5, 1.0);
            case 3: return float3(1.0, 0.9, 0.2);
            case 4: return float3(1.0, 0.35, 1.0);
            default: return float3(0.2, 0.95, 0.95);
        }
    }

    // p[0] canvas width, p[1] canvas height, p[2] time (s), p[3] screen count (uint bits),
    // p[4] frame number (uint bits), p[5] opacity, p[8 + 4i ...] screen i: x, y, width, height.
    fragment float4 pattern_fragment(VOut in [[stage_in]], constant float *p [[buffer(0)]]) {
        float2 px = in.position.xy;
        float time = p[2];
        uint count = as_type<uint>(p[3]);
        uint frame = as_type<uint>(p[4]);
        float4 c = float4(0.0);

        if (fmod(px.x, 120.0) < 1.0 || fmod(px.y, 120.0) < 1.0) c = over(c, float3(1.0), 0.18);

        for (uint i = 0; i < count; i++) {
            float4 r = float4(p[8 + i * 4], p[9 + i * 4], p[10 + i * 4], p[11 + i * 4]);
            if (px.x < r.x || px.x >= r.x + r.z || px.y < r.y || px.y >= r.y + r.w) continue;
            float3 col = screenColor(i);
            float lx = px.x - r.x;
            float ly = px.y - r.y;
            if (lx < 4.0 || ly < 4.0 || lx >= r.z - 4.0 || ly >= r.w - 4.0) c = over(c, col, 0.95);
            // Screen number: i + 1 squares at the top left.
            if (ly >= 16.0 && ly < 44.0 && lx >= 16.0) {
                float sx = lx - 16.0;
                uint k = uint(sx / 44.0);
                if (k <= i && fmod(sx, 44.0) < 28.0) c = over(c, col, 0.95);
            }
            // Frame counter: 12 bits, most significant first, at the bottom left.
            if (ly >= r.w - 84.0 && ly < r.w - 44.0 && lx >= 16.0) {
                float sx = lx - 16.0;
                uint k = uint(sx / 48.0);
                if (k < 12 && fmod(sx, 48.0) < 40.0) {
                    bool on = ((frame >> (11 - k)) & 1u) != 0u;
                    c = over(c, on ? float3(1.0) : float3(0.15), on ? 1.0 : 0.7);
                }
            }
        }

        // A bar that crosses the whole canvas every 4 seconds.
        float barX = fract(time / 4.0) * p[0];
        if (abs(px.x - barX) < 8.0) c = over(c, float3(1.0), 1.0);
        return c * p[5];
    }

    // Packs a finished screen as 4:2:2 YUV ("2vuy", Cb Y0 Cr Y1, BT.709 video range) into a buffer half
    // the output width. p: output width, output height.
    fragment float4 screen_pack_fragment(VOut in [[stage_in]],
                                         texture2d<float> screen [[texture(0)]],
                                         constant float *p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 outSize = float2(p[0], p[1]);
        float x = floor(in.position.x) * 2.0;
        float y = floor(in.position.y);
        float3 a = screen.sample(s, float2(x + 0.5, y + 0.5) / outSize).rgb;
        float3 b = screen.sample(s, float2(x + 1.5, y + 0.5) / outSize).rgb;
        const float3 kY = float3(0.2126, 0.7152, 0.0722);
        float ya = dot(a, kY);
        float yb = dot(b, kY);
        float3 m = (a + b) * 0.5;
        float ym = dot(m, kY);
        float cb = (m.b - ym) / 1.8556;
        float cr = (m.r - ym) / 1.5748;
        float Y0 = (16.0 + 219.0 * ya) / 255.0;
        float Y1 = (16.0 + 219.0 * yb) / 255.0;
        float Cb = (128.0 + 224.0 * cb) / 255.0;
        float Cr = (128.0 + 224.0 * cr) / 255.0;
        return float4(Cr, Y0, Cb, Y1);
    }
    """

    public init(canvasWidth: Int, canvasHeight: Int, screens: [ScreenRegion],
                outputWidth: Int = 1920, outputHeight: Int = 1080) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositorError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandFailed }
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.screens = screens
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.device = device
        self.queue = queue

        func makeTarget(_ width: Int, _ height: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let texture = device.makeTexture(descriptor: d) else { throw CompositorError.textureCacheFailed }
            return texture
        }
        canvasTexture = try makeTarget(canvasWidth, canvasHeight)
        screenTextures = try screens.map { try makeTarget($0.width, $0.height) }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: CanvasCompositor.shaderSource, options: nil)
        } catch {
            throw CompositorError.shaderCompileFailed("\(error)")
        }

        func pipeline(_ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "canvas_vertex")
            desc.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = desc.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            if blended {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                throw CompositorError.pipelineFailed("\(error)")
            }
        }
        layerPipeline = try pipeline("layer_fragment", blended: true)
        patternPipeline = try pipeline("pattern_fragment", blended: true)
        packPipeline = try pipeline("screen_pack_fragment", blended: false)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CompositorError.textureCacheFailed }
        textureCache = cache

        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: outputWidth / 2,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4 * max(1, screens.count)]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw CompositorError.poolFailed(status) }
        packedPool = pool
    }

    private func cvTexture(from buffer: CVPixelBuffer) -> (texture: MTLTexture, backing: CVMetalTexture)? {
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cv)
        guard status == kCVReturnSuccess, let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return (texture, cv)
    }

    /// A texture view of a BGRA pixel buffer (zero copy), for use as a layer.
    public func makeTexture(from buffer: CVPixelBuffer) -> RetainedTexture? {
        guard let t = cvTexture(from: buffer) else { return nil }
        return RetainedTexture(texture: t.texture, backing: t.backing)
    }

    private func patternParameters(frameNumber: UInt32, time: Double) -> [Float] {
        var p = [Float](repeating: 0, count: 8 + 4 * screens.count)
        p[0] = Float(canvasWidth)
        p[1] = Float(canvasHeight)
        p[2] = Float(time)
        p[3] = Float(bitPattern: UInt32(screens.count))
        p[4] = Float(bitPattern: frameNumber)
        p[5] = 1
        for (i, s) in screens.enumerated() {
            p[8 + i * 4] = Float(s.x)
            p[9 + i * 4] = Float(s.y)
            p[10 + i * 4] = Float(s.width)
            p[11 + i * 4] = Float(s.height)
        }
        return p
    }

    private func draw(_ layer: CanvasLayerDraw, encoder: MTLRenderCommandEncoder,
                      width: Int, height: Int, pattern: [Float]?) {
        guard layer.opacity > 0 else { return }
        let full = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height),
                               znear: 0, zfar: 1)

        guard let texture = layer.texture else {
            guard var p = pattern else { return }
            p[5] = layer.opacity
            encoder.setViewport(full)
            encoder.setRenderPipelineState(patternPipeline)
            encoder.setFragmentBytes(&p, length: p.count * MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return
        }

        let area = layer.rect ?? ScreenRegion(x: 0, y: 0, width: width, height: height)
        guard area.width > 0, area.height > 0 else { return }
        var dest = area
        var uvScale = SIMD2<Float>(1, 1)
        let cw = Float(max(1, layer.contentWidth))
        let ch = Float(max(1, layer.contentHeight))
        switch layer.fit {
        case .stretch:
            break
        case .contain:
            let s = min(Float(area.width) / cw, Float(area.height) / ch)
            let w = max(1, Int((cw * s).rounded()))
            let h = max(1, Int((ch * s).rounded()))
            dest = ScreenRegion(x: area.x + (area.width - w) / 2, y: area.y + (area.height - h) / 2,
                                width: w, height: h)
        case .cover:
            let areaAspect = Float(area.width) / Float(area.height)
            let contentAspect = cw / ch
            uvScale = areaAspect > contentAspect
                ? SIMD2<Float>(1, contentAspect / areaAspect)
                : SIMD2<Float>(areaAspect / contentAspect, 1)
        }
        let offset = (SIMD2<Float>(1, 1) - uvScale) * 0.5
        var p: [Float] = [uvScale.x, uvScale.y, offset.x, offset.y, layer.opacity]
        encoder.setViewport(MTLViewport(originX: Double(dest.x), originY: Double(dest.y),
                                        width: Double(dest.width), height: Double(dest.height),
                                        znear: 0, zfar: 1))
        encoder.setRenderPipelineState(layerPipeline)
        encoder.setFragmentTexture(texture.texture, index: 0)
        encoder.setFragmentBytes(&p, length: p.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draw the master, then every screen's composition, and pack the screens. `completion` runs on a
    /// Metal thread with one packed-YUV frame per screen (in the order of `screens`) and the GPU time (ms).
    public func render(master: [CanvasLayerDraw], screens drawn: [CanvasScreenDraw],
                       frameNumber: UInt32, time: Double,
                       completion: @escaping ([CVPixelBuffer], Double) -> Void) throws {
        guard drawn.count == screens.count else { throw CompositorError.commandFailed }
        guard let command = queue.makeCommandBuffer() else { throw CompositorError.commandFailed }
        let patternParams = patternParameters(frameNumber: frameNumber, time: time)

        // Master composition.
        let masterPass = MTLRenderPassDescriptor()
        masterPass.colorAttachments[0].texture = canvasTexture
        masterPass.colorAttachments[0].loadAction = .clear
        masterPass.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.07, 1)
        masterPass.colorAttachments[0].storeAction = .store
        guard let masterEncoder = command.makeRenderCommandEncoder(descriptor: masterPass) else {
            throw CompositorError.commandFailed
        }
        for layer in master {
            draw(layer, encoder: masterEncoder, width: canvasWidth, height: canvasHeight, pattern: patternParams)
        }
        masterEncoder.endEncoding()

        // One composition per screen, then its packed output frame.
        var frames: [CVPixelBuffer] = []
        var backings: [CVMetalTexture] = []
        for (i, region) in screens.enumerated() {
            let screenPass = MTLRenderPassDescriptor()
            screenPass.colorAttachments[0].texture = screenTextures[i]
            screenPass.colorAttachments[0].loadAction = .clear
            screenPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            screenPass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: screenPass) else {
                throw CompositorError.commandFailed
            }
            if drawn[i].showMaster {
                // The slice of the master under this screen (1:1 when the screen is placed on whole pixels).
                var p: [Float] = [Float(region.width) / Float(canvasWidth), Float(region.height) / Float(canvasHeight),
                                  Float(region.x) / Float(canvasWidth), Float(region.y) / Float(canvasHeight), 1]
                encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(region.width),
                                                height: Double(region.height), znear: 0, zfar: 1))
                encoder.setRenderPipelineState(layerPipeline)
                encoder.setFragmentTexture(canvasTexture, index: 0)
                encoder.setFragmentBytes(&p, length: p.count * MemoryLayout<Float>.size, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            for layer in drawn[i].layers {
                draw(layer, encoder: encoder, width: region.width, height: region.height, pattern: nil)
            }
            encoder.endEncoding()

            var output: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, packedPool, &output)
            guard status == kCVReturnSuccess, let frame = output else { throw CompositorError.bufferFailed(status) }
            guard let target = cvTexture(from: frame) else { throw CompositorError.textureCacheFailed }
            let packPass = MTLRenderPassDescriptor()
            packPass.colorAttachments[0].texture = target.texture
            packPass.colorAttachments[0].loadAction = .dontCare
            packPass.colorAttachments[0].storeAction = .store
            guard let packEncoder = command.makeRenderCommandEncoder(descriptor: packPass) else {
                throw CompositorError.commandFailed
            }
            var q: [Float] = [Float(outputWidth), Float(outputHeight)]
            packEncoder.setRenderPipelineState(packPipeline)
            packEncoder.setFragmentTexture(screenTextures[i], index: 0)
            packEncoder.setFragmentBytes(&q, length: q.count * MemoryLayout<Float>.size, index: 0)
            packEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            packEncoder.endEncoding()
            frames.append(frame)
            backings.append(target.backing)
        }

        let delivered = frames
        let keepAlive = backings
        command.addCompletedHandler { buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            completion(delivered, gpuMs)
            withExtendedLifetime((keepAlive, master, drawn)) {}
        }
        command.commit()

        renderCount += 1
        if renderCount % 120 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
    }
}
