import Dispatch
import Foundation
import Engine

// StageEngine: the output process.
//
// Usage:
//   StageEngine [--seconds N]                      time a bare 60 Hz clock (no video, no GPU)
//   StageEngine --list-decklink                    list the DeckLink devices the driver sees
//   StageEngine --video FILE [--seconds N] [--warmup N]
//                                                  engine spike: looping video + text through Metal,
//                                                  frames discarded by a test sink
//   StageEngine --video FILE --decklink INDEX [--depth N] [--seconds N] [--warmup N]
//                                                  same, sent out one DeckLink SDI connector as
//                                                  1080p59.94, paced by the card's clock
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
let warmup = value(after: "--warmup").flatMap(Double.init) ?? 2.0

if arguments.contains("--list-decklink") {
    let devices = DeckLinkOutputBridge.listDevices()
    if devices.isEmpty {
        print("No DeckLink devices found. Is Blackmagic Desktop Video installed, the chassis connected,")
        print("and the SDK present in vendor/DeckLinkSDK/include when this was built?")
    }
    for d in devices {
        print("[\(d.index)] \(d.displayName)  (\(d.modelName))  output=\(d.canOutput ? "yes" : "no")  1080p59.94 BGRA=\(d.supports1080p5994 ? "yes" : "no")  formats[\(d.ioSupport)]  queryResult=\(d.outputQueryResult)")
    }
    exit(0)
}

if let videoPath = value(after: "--video") {
    guard FileManager.default.isReadableFile(atPath: videoPath),
          let probe = FileHandle(forReadingAtPath: videoPath) else {
        print("""
        Cannot open \(videoPath).
        If the file exists, macOS is probably blocking access to this folder (Downloads, Desktop and
        Documents are protected). Copy the video to a folder such as ~/Projects/L252/stage-test-media
        and pass that path.
        """)
        exit(1)
    }
    try? probe.close()
    do {
        let sink: OutputSink
        if let indexText = value(after: "--decklink") {
            guard let index = Int(indexText) else {
                print("--decklink needs a device number (see --list-decklink)")
                exit(1)
            }
            let depth = value(after: "--depth").flatMap(Int.init) ?? 4
            sink = try DeckLinkOutputSink(deviceIndex: index, depth: depth)
        } else {
            sink = NullOutputSink(name: "null", targetFPS: 60)
        }
        let runner = try await SpikeRunner(videoURL: URL(fileURLWithPath: videoPath),
                                           output: sink, targetFPS: 60)
        print("StageEngine spike: \(videoPath)")
        print("  output: \(sink.name)")
        print("  \(seconds) s (after \(warmup) s warm-up), 1920x1080")
        let report = try runner.run(seconds: seconds, warmup: warmup)
        print(report)
    } catch {
        print("StageEngine spike failed: \(error.localizedDescription)")
        print("  (\(error))")
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
