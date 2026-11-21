import CoreVideo
import Foundation
import Metal

/// A rectangle of the canvas (in canvas pixels) that is sent to one output.
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

/// Renders one large canvas (for example 5760x1080 or 6000x1920) and cuts "virtual screens" out of it.
/// Each screen becomes a 1080p packed-YUV frame for one SDI output. If a screen's rectangle is not
/// 1920x1080 it is scaled to fit.
///
/// The canvas holds an optional background (a video, scaled to cover the whole canvas) and an animated
/// test pattern: a grid, a coloured border and numbered squares on every screen, a binary frame counter
/// on every screen, and a bar sweeping across the whole canvas. The sweeping bar and the counters show
/// whether neighbouring outputs stay in step.
///
/// Call `render` from one thread only.
public final class CanvasCompositor {
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let screens: [ScreenRegion]
    public let outputWidth: Int
    public let outputHeight: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let canvasTexture: MTLTexture
    private let coverPipeline: MTLRenderPipelineState
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

    // A video scaled to cover the whole canvas (the part that does not fit is cropped).
    fragment float4 cover_fragment(VOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   constant float2 &scale [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = (in.uv - 0.5) * scale + 0.5;
        return tex.sample(s, uv);
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
    // p[4] frame number (uint bits), p[8 + 4i ...] screen i: x, y, width, height.
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
            if (ly >= r.w - 44.0 && ly < r.w - 24.0 && lx >= 16.0) {
                float sx = lx - 16.0;
                uint k = uint(sx / 24.0);
                if (k < 12 && fmod(sx, 24.0) < 20.0) {
                    bool on = ((frame >> (11 - k)) & 1u) != 0u;
                    c = over(c, on ? float3(1.0) : float3(0.15), on ? 1.0 : 0.7);
                }
            }
        }

        // A bar that crosses the whole canvas every 4 seconds.
        float barX = fract(time / 4.0) * p[0];
        if (abs(px.x - barX) < 8.0) c = over(c, float3(1.0), 1.0);
        return c;
    }

    // Cuts one screen out of the canvas and packs it as 4:2:2 YUV ("2vuy", Cb Y0 Cr Y1, BT.709 video
    // range) into a buffer half the output width. p: rect x, y, w, h, output w, h, canvas w, h.
    fragment float4 screen_pack_fragment(VOut in [[stage_in]],
                                         texture2d<float> canvas [[texture(0)]],
                                         constant float *p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 origin = float2(p[0], p[1]);
        float2 size = float2(p[2], p[3]);
        float2 outSize = float2(p[4], p[5]);
        float2 canvasSize = float2(p[6], p[7]);
        float x = floor(in.position.x) * 2.0;
        float y = floor(in.position.y);
        float2 uvA = (origin + float2(x + 0.5, y + 0.5) * size / outSize) / canvasSize;
        float2 uvB = (origin + float2(x + 1.5, y + 0.5) * size / outSize) / canvasSize;
        float3 a = canvas.sample(s, uvA).rgb;
        float3 b = canvas.sample(s, uvB).rgb;
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

        let canvasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: canvasWidth, height: canvasHeight, mipmapped: false)
        canvasDescriptor.usage = [.renderTarget, .shaderRead]
        canvasDescriptor.storageMode = .private
        guard let canvas = device.makeTexture(descriptor: canvasDescriptor) else {
            throw CompositorError.textureCacheFailed
        }
        canvasTexture = canvas

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
        coverPipeline = try pipeline("cover_fragment", blended: true)
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

    private func texture(from buffer: CVPixelBuffer) -> (texture: MTLTexture, backing: CVMetalTexture)? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    /// Draw the canvas and cut the screens. `completion` runs on a Metal thread with one packed-YUV frame
    /// per screen (in the order of `screens`) and the GPU time in milliseconds.
    public func render(background: CVPixelBuffer?, frameNumber: UInt32, time: Double, pattern: Bool,
                       completion: @escaping ([CVPixelBuffer], Double) -> Void) throws {
        guard let command = queue.makeCommandBuffer() else { throw CompositorError.commandFailed }

        // Pass 1: the canvas.
        var backgroundTexture: (texture: MTLTexture, backing: CVMetalTexture)?
        if let background { backgroundTexture = texture(from: background) }

        let canvasPass = MTLRenderPassDescriptor()
        canvasPass.colorAttachments[0].texture = canvasTexture
        canvasPass.colorAttachments[0].loadAction = .clear
        canvasPass.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.07, 1)
        canvasPass.colorAttachments[0].storeAction = .store
        guard let canvasEncoder = command.makeRenderCommandEncoder(descriptor: canvasPass) else {
            throw CompositorError.commandFailed
        }
        if let backgroundTexture, let background {
            let canvasAspect = Float(canvasWidth) / Float(canvasHeight)
            let videoAspect = Float(CVPixelBufferGetWidth(background)) / Float(CVPixelBufferGetHeight(background))
            var scale = canvasAspect > videoAspect
                ? SIMD2<Float>(1, videoAspect / canvasAspect)
                : SIMD2<Float>(canvasAspect / videoAspect, 1)
            canvasEncoder.setRenderPipelineState(coverPipeline)
            canvasEncoder.setFragmentTexture(backgroundTexture.texture, index: 0)
            canvasEncoder.setFragmentBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            canvasEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if pattern {
            var p = [Float](repeating: 0, count: 8 + 4 * screens.count)
            p[0] = Float(canvasWidth)
            p[1] = Float(canvasHeight)
            p[2] = Float(time)
            p[3] = Float(bitPattern: UInt32(screens.count))
            p[4] = Float(bitPattern: frameNumber)
            for (i, s) in screens.enumerated() {
                p[8 + i * 4] = Float(s.x)
                p[9 + i * 4] = Float(s.y)
                p[10 + i * 4] = Float(s.width)
                p[11 + i * 4] = Float(s.height)
            }
            canvasEncoder.setRenderPipelineState(patternPipeline)
            canvasEncoder.setFragmentBytes(&p, length: p.count * MemoryLayout<Float>.size, index: 0)
            canvasEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        canvasEncoder.endEncoding()

        // Pass 2..: one packed frame per screen.
        var frames: [CVPixelBuffer] = []
        var keepAlive: [CVMetalTexture] = []
        for screen in screens {
            var output: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, packedPool, &output)
            guard status == kCVReturnSuccess, let frame = output else { throw CompositorError.bufferFailed(status) }
            guard let target = texture(from: frame) else { throw CompositorError.textureCacheFailed }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw CompositorError.commandFailed
            }
            var p: [Float] = [Float(screen.x), Float(screen.y), Float(screen.width), Float(screen.height),
                              Float(outputWidth), Float(outputHeight), Float(canvasWidth), Float(canvasHeight)]
            encoder.setRenderPipelineState(packPipeline)
            encoder.setFragmentTexture(canvasTexture, index: 0)
            encoder.setFragmentBytes(&p, length: p.count * MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            frames.append(frame)
            keepAlive.append(target.backing)
        }

        let backing = backgroundTexture?.backing
        let delivered = frames
        let textures = keepAlive
        command.addCompletedHandler { buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            completion(delivered, gpuMs)
            withExtendedLifetime((textures, backing)) {}
        }
        command.commit()

        renderCount += 1
        if renderCount % 120 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
    }
}
