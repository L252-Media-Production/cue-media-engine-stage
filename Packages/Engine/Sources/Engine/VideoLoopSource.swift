import AVFoundation
import CoreVideo
import Foundation

public enum VideoError: Error {
    case noVideoTrack
    case readerFailed(String)
}

/// Plays a video file in a seamless loop using hardware decode (AVAssetReader), keeping a few
/// decoded BGRA frames ahead of the render loop. Ask for the frame to show at a given time with
/// `frame(at:)`.
public final class VideoLoopSource: @unchecked Sendable {
    public let duration: Double
    public let nominalFPS: Double

    private struct Decoded {
        var time: Double
        var buffer: CVPixelBuffer
    }

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let lock = NSLock()
    private var queued: [Decoded] = []
    private var current: Decoded?
    private var stopping = false
    private var thread: Thread?
    private var underrunCount = 0
    private let maxQueued = 8

    private init(asset: AVURLAsset, track: AVAssetTrack, duration: Double, fps: Double) {
        self.asset = asset
        self.track = track
        self.duration = duration
        self.nominalFPS = fps
    }

    public static func open(url: URL) async throws -> VideoLoopSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack
        }
        let range = try await track.load(.timeRange)
        let fps = try await track.load(.nominalFrameRate)
        return VideoLoopSource(asset: asset, track: track, duration: range.duration.seconds, fps: Double(fps))
    }

    /// Number of times the render loop asked for a frame and the decoder had fallen behind.
    public var underruns: Int {
        lock.lock()
        defer { lock.unlock() }
        return underrunCount
    }

    public func start() {
        lock.lock()
        stopping = false
        lock.unlock()
        let thread = Thread { [self] in decodeLoop() }
        thread.name = "stage.video.decode"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    /// The frame that should be on screen at playback time `t` (seconds since the loop started).
    public func frame(at t: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        while let next = queued.first, next.time <= t {
            current = next
            queued.removeFirst()
        }
        if let current {
            // If the newest frame is more than two frame times old, the decoder is not keeping up.
            if t - current.time > 2.0 / max(nominalFPS, 1) { underrunCount += 1 }
            return current.buffer
        }
        return nil
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func queuedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return queued.count
    }

    private func decodeLoop() {
        var loopIndex = 0.0
        while !isStopping {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }

            while !isStopping, let sample = output.copyNextSampleBuffer() {
                guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                while !isStopping && queuedCount() >= maxQueued {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                lock.lock()
                queued.append(Decoded(time: loopIndex * duration + pts, buffer: image))
                lock.unlock()
            }
            reader.cancelReading()
            loopIndex += 1
        }
    }
}
