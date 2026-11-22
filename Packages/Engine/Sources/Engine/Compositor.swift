import CoreVideo
import Foundation
import Metal

public enum CompositorError: Error {
    case noMetalDevice
    case shaderCompileFailed(String)
    case pipelineFailed(String)
    case textureCacheFailed
    case poolFailed(CVReturn)
    case bufferFailed(CVReturn)
    case commandFailed
    case textContextFailed
}

/// A Metal texture plus whatever must stay alive while the GPU reads it.
public final class RetainedTexture {
    public let texture: MTLTexture
    private let backing: CVMetalTexture?

    init(texture: MTLTexture, backing: CVMetalTexture?) {
        self.texture = texture
        self.backing = backing
    }

    /// Wrap a texture that is not backed by a CVPixelBuffer (for example the text layer).
    public convenience init(texture: MTLTexture) {
        self.init(texture: texture, backing: nil)
    }
}

/// One layer to draw: a texture and an opacity. Layers are drawn in array order, first at the bottom.
public struct LayerDraw {
    public var texture: RetainedTexture
    public var opacity: Float

    public init(texture: RetainedTexture, opacity: Float = 1) {
        self.texture = texture
        self.opacity = opacity
    }
}

/// The pixel layout of the frames a `Compositor` hands to its output.
public enum OutputPixelFormat {
    /// 32-bit BGRA, full frame size.
    case bgra
    /// 8-bit 4:2:2 YUV (BT.709, video range) in the "2vuy" byte order Cb Y0 Cr Y1, which is what SDI
    /// cards take. It is stored in a BGRA pixel buffer half the frame's width: each 4-byte texel
    /// holds two pixels, so a 1920x1080 frame arrives as a 960x1080 buffer.
    case yuv8
}

/// GPU compositor: draws layers (premultiplied alpha, source-over) into a pooled BGRA pixel buffer
/// that can be handed to an `OutputSink`. Call `render` from one thread only.
public final class Compositor {
    public let width: Int
    public let height: Int
    public let device: MTLDevice
    public let outputFormat: OutputPixelFormat

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let yuvPipeline: MTLRenderPipelineState
    private let yuvPool: CVPixelBufferPool?
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private var renderCount = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
        VOut o;
        o.position = float4(pos[vid], 0.0, 1.0);
        o.uv = uvs[vid];
        return o;
    }

    fragment float4 layer_fragment(VOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   constant float &opacity [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        return c * opacity; // premultiplied alpha
    }

    // Packs two horizontally adjacent pixels into one 4:2:2 texel. The target is bgra8Unorm, so
    // (r, g, b, a) lands in memory as B G R A; writing (Cr, Y0, Cb, Y1) gives Cb Y0 Cr Y1 ("2vuy").
    fragment float4 yuv_pack_fragment(VOut in [[stage_in]],
                                      texture2d<float, access::read> src [[texture(0)]]) {
        uint x = uint(in.position.x) * 2;
        uint y = uint(in.position.y);
        float3 a = src.read(uint2(x, y)).rgb;
        float3 b = src.read(uint2(x + 1, y)).rgb;
        // BT.709 luma (full range 0...1) per pixel, chroma from the average of the pair.
        const float3 kY = float3(0.2126, 0.7152, 0.0722);
        float ya = dot(a, kY);
        float yb = dot(b, kY);
        float3 m = (a + b) * 0.5;
        float ym = dot(m, kY);
        float cb = (m.b - ym) / 1.8556;
        float cr = (m.r - ym) / 1.5748;
        // Video range: Y 16...235, Cb/Cr 16...240 (centred on 128).
        float Y0 = (16.0 + 219.0 * ya) / 255.0;
        float Y1 = (16.0 + 219.0 * yb) / 255.0;
        float Cb = (128.0 + 224.0 * cb) / 255.0;
        float Cr = (128.0 + 224.0 * cr) / 255.0;
        return float4(Cr, Y0, Cb, Y1);
    }
    """

    public init(width: Int = 1920, height: Int = 1080, outputFormat: OutputPixelFormat = .bgra) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositorError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandFailed }
        self.width = width
        self.height = height
        self.outputFormat = outputFormat
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Compositor.shaderSource, options: nil)
        } catch {
            throw CompositorError.shaderCompileFailed("\(error)")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        desc.fragmentFunction = library.makeFunction(name: "layer_fragment")
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        let yuvDesc = MTLRenderPipelineDescriptor()
        yuvDesc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        yuvDesc.fragmentFunction = library.makeFunction(name: "yuv_pack_fragment")
        yuvDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            yuvPipeline = try device.makeRenderPipelineState(descriptor: yuvDesc)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CompositorError.textureCacheFailed }
        textureCache = cache

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary,
                                             bufferAttributes as CFDictionary, &newPool)
        guard status == kCVReturnSuccess, let newPool else { throw CompositorError.poolFailed(status) }
        pool = newPool

        if outputFormat == .yuv8 {
            let yuvAttributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width / 2,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var packedPool: CVPixelBufferPool?
            let packedStatus = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary,
                                                       yuvAttributes as CFDictionary, &packedPool)
            guard packedStatus == kCVReturnSuccess, let packedPool else { throw CompositorError.poolFailed(packedStatus) }
            yuvPool = packedPool
        } else {
            yuvPool = nil
        }
    }

    /// A texture view of a BGRA pixel buffer (zero copy).
    public func makeTexture(from buffer: CVPixelBuffer) -> RetainedTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return RetainedTexture(texture: texture, backing: cvTexture)
    }

    /// Draw `layers` into a new frame. `completion` runs on a Metal thread with the finished
    /// frame and the GPU time in milliseconds. The caller must release the frame when done with it
    /// so it returns to the pool.
    public func render(_ layers: [LayerDraw],
                       completion: @escaping (CVPixelBuffer, Double) -> Void) throws {
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard status == kCVReturnSuccess, let frame = output else { throw CompositorError.bufferFailed(status) }
        guard let target = makeTexture(from: frame) else { throw CompositorError.textureCacheFailed }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw CompositorError.commandFailed
        }
        encoder.setRenderPipelineState(pipeline)
        for layer in layers {
            encoder.setFragmentTexture(layer.texture.texture, index: 0)
            var opacity = layer.opacity
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        // For YUV outputs a second pass packs the finished frame; the caller gets the packed buffer.
        var deliver = frame
        var packedTarget: RetainedTexture?
        if let yuvPool {
            var packedOut: CVPixelBuffer?
            let packedStatus = CVPixelBufferPoolCreatePixelBuffer(nil, yuvPool, &packedOut)
            guard packedStatus == kCVReturnSuccess, let packed = packedOut else { throw CompositorError.bufferFailed(packedStatus) }
            guard let packedTexture = makeTexture(from: packed) else { throw CompositorError.textureCacheFailed }
            let packPass = MTLRenderPassDescriptor()
            packPass.colorAttachments[0].texture = packedTexture.texture
            packPass.colorAttachments[0].loadAction = .dontCare
            packPass.colorAttachments[0].storeAction = .store
            guard let packEncoder = command.makeRenderCommandEncoder(descriptor: packPass) else {
                throw CompositorError.commandFailed
            }
            packEncoder.setRenderPipelineState(yuvPipeline)
            packEncoder.setFragmentTexture(target.texture, index: 0)
            packEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            packEncoder.endEncoding()
            deliver = packed
            packedTarget = packedTexture
        }

        let keepAlive = layers.map { $0.texture }
        command.addCompletedHandler { buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            completion(deliver, gpuMs)
            withExtendedLifetime((target, packedTarget, frame, keepAlive)) {}
        }
        command.commit()

        renderCount += 1
        if renderCount % 120 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
    }
}
