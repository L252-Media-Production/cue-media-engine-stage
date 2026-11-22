import CoreVideo
import Metal
import XCTest
@testable import Engine

final class CompositorTests: XCTestCase {
    func testRunningStats() {
        let stats = RunningStats()
        stats.add(2)
        stats.add(4)
        let s = stats.snapshot
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.mean, 3, accuracy: 1e-9)
        XCTAssertEqual(s.max, 4, accuracy: 1e-9)
    }

    /// Compiles the shaders, draws a text layer into a frame and waits for the GPU.
    func testShadersCompileAndRenderOneFrame() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device")
        let compositor = try Compositor(width: 640, height: 360)
        let text = try TextLayer(device: compositor.device, width: 640, height: 360)
        text.update([TextLine(text: "Test", fontSize: 64, centerYFromTop: 180)])

        let done = expectation(description: "frame rendered")
        var gpuMs = -1.0
        var size = (0, 0)
        try compositor.render([LayerDraw(texture: text.layer)]) { frame, ms in
            gpuMs = ms
            size = (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(gpuMs, 0)
        XCTAssertEqual(size.0, 640)
        XCTAssertEqual(size.1, 360)
    }
}
