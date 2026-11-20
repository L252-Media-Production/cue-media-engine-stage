import Dispatch
import Foundation
import Engine

// StageEngine: the output process. For now it runs a 60 Hz clock for a few seconds
// and prints the timing summary, as a baseline for the engine spike.
//
// Usage: StageEngine [seconds]

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5.0
let logger = FrameTimingLogger(targetFPS: 60)
let queue = DispatchQueue(label: "stage.engine.clock", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
timer.setEventHandler { logger.recordFrame() }
timer.resume()

print("StageEngine: timing a 60 Hz clock for \(seconds) s ...")
Thread.sleep(forTimeInterval: seconds)
timer.cancel()
print(logger.summary())
