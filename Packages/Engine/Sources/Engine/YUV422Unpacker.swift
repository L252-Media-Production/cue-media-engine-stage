import CoreVideo
import Foundation
import Metal

/// Converts packed 8-bit 4:2:2 YUV ("2vuy": Cb Y0 Cr Y1, BT.709, video range), as SDI cards deliver it,
/// into a full-size BGRA pixel buffer the compositor can draw.
///
/// The packed frame arrives in a BGRA pixel buffer half the frame's width (each 4-byte texel holds two
/// pixels), the same layout the compositor writes for SDI output. `unpack` runs a small GPU pass and
/// waits for it, so call it from one thread and not from a latency-critical callback.
public final class YUV422Unpacker {
    public let width: Int
    public let height: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private var count = 0

    /// Time spent in the last conversions (milliseconds), for the report.
    public private(set) var lastMs: Double = 0
    public private(set) var maxMs: Double = 0
    public private(set) var totalMs: Double = 0
    public private(set) var conversions: Int = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 position [[position]];
    };

    vertex VOut unpack_vertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        VOut o;
        o.position = float4(pos[vid], 0.0, 1.0);
        return o;
    }

    // The packed texture is bgra8Unorm, so a texel reads back as (r, g, b, a) = (Cr, Y0, Cb, Y1).
    fragment float4 yuv_unpack_fragment(VOut in [[stage_in]],
                                        texture2d<float, access::read> src [[texture(0)]]) {
        uint x = uint(in.position.x);
        uint y = uint(in.position.y);
        uint tx = x >> 1;
        float4 t = src.read(uint2(tx, y));
        bool odd = (x & 1) != 0;
        float Y = odd ? t.a : t.g;
        float Cb = t.b;
        float Cr = t.r;
        if (odd) {
            // Chroma is sited on the even pixel: the odd pixel takes the average with the next pair.
            uint nx = min(tx + 1, src.get_width() - 1);
            float4 n = src.read(uint2(nx, y));
            Cb = 0.5 * (Cb + n.b);
            Cr = 0.5 * (Cr + n.r);
        }
        float yy = (Y * 255.0 - 16.0) / 219.0;
        float cb = (Cb * 255.0 - 128.0) / 224.0;
        float cr = (Cr * 255.0 - 128.0) / 224.0;
        float3 rgb = float3(yy + 1.5748 * cr,
                            yy - 0.1873 * cb - 0.4681 * cr,
                            yy + 1.8556 * cb);
        return float4(clamp(rgb, 0.0, 1.0), 1.0);
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
            library = try device.makeLibrary(source: YUV422Unpacker.shaderSource, options: nil)
        } catch {
            throw CompositorError.shaderCompileFailed("\(error)")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "unpack_vertex")
        desc.fragmentFunction = library.makeFunction(name: "yuv_unpack_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw CompositorError.pipelineFailed("\(error)")
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CompositorError.textureCacheFailed }
        textureCache = cache

        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary,
                                             attributes as CFDictionary, &newPool)
        guard status == kCVReturnSuccess, let newPool else { throw CompositorError.poolFailed(status) }
        pool = newPool
    }

    private func texture(from buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    /// The full-size BGRA frame for a packed 4:2:2 frame (`width / 2` x `height`), or nil on failure.
    public func unpack(_ packed: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(packed) == width / 2, CVPixelBufferGetHeight(packed) == height else {
            return nil
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let frame = output,
              let source = texture(from: packed),
              let target = texture(from: frame) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.0
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source.0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        let ms = (command.gpuEndTime - command.gpuStartTime) * 1000.0
        lastMs = ms
        maxMs = max(maxMs, ms)
        totalMs += ms
        conversions += 1
        count += 1
        if count % 120 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
        withExtendedLifetime((source.1, target.1)) {}
        return frame
    }

    public var meanMs: Double { conversions > 0 ? totalMs / Double(conversions) : 0 }
}
