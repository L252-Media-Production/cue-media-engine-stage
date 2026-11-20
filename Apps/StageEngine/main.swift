import Dispatch
import Foundation
import Engine

// StageEngine: the output process.
//
// Usage:
//   StageEngine [--seconds N]                  time a bare 60 Hz clock (no video, no GPU)
//   StageEngine --video FILE [--seconds N]     engine spike: looping video + text layer through Metal
//
// In Xcode, set arguments under Product > Scheme > Edit Scheme > Run > Arguments.

// Xcode's console is a pipe, so stdout would otherwise be block-buffered and show nothing until exit.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let seconds = value(after: "--seconds").flatMap(Double.init) ?? 10.0

if let videoPath = value(after: "--video") {
    do {
        let sink = NullOutputSink(name: "null", targetFPS: 60)
        let runner = try await SpikeRunner(videoURL: URL(fileURLWithPath: videoPath),
                                           output: sink, targetFPS: 60)
        print("StageEngine spike: \(videoPath) for \(seconds) s at 1920x1080, 60 fps ...")
        let report = try runner.run(seconds: seconds)
        print(report)
    } catch {
        print("StageEngine spike failed: \(error)")
        exit(1)
    }
} else {
    let logger = FrameTimingLogger(targetFPS: 60)
    let queue = DispatchQueue(label: "stage.engine.clock", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
    timer.setEventHandler { logger.recordFrame() }
    timer.resume()

    print("StageEngine: timing a bare 60 Hz clock for \(seconds) s ...")
    try? await Task.sleep(for: .seconds(seconds))
    timer.cancel()
    print(logger.summary())
}
