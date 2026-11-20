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

/// GPU compositor: draws layers (premultiplied alpha, source-over) into a pooled BGRA pixel buffer
/// that can be handed to an `OutputSink`. Call `render` from one thread only.
public final class Compositor {
    public let width: Int
    public let height: Int
    public let device: MTLDevice

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
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
    """

    public init(width: Int = 1920, height: Int = 1080) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositorError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw CompositorError.commandFailed }
        self.width = width
        self.height = height
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

        let keepAlive = layers.map { $0.texture }
        command.addCompletedHandler { buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            completion(frame, gpuMs)
            withExtendedLifetime((target, keepAlive)) {}
        }
        command.commit()

        renderCount += 1
        if renderCount % 120 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
    }
}
