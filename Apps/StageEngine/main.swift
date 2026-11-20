import Dispatch
import Foundation
import Engine

// StageEngine: the output process.
//
// Usage:
//   StageEngine [--seconds N]                      time a bare 60 Hz clock (no video, no GPU)
//   StageEngine --list-decklink                    list the DeckLink devices the driver sees
//   StageEngine --ndi-list [--wait N]              list NDI sources on the network
//
//   Input (pick one):   --video FILE               a looping video file
//                       --ndi-in TEXT              the NDI source whose name contains TEXT
//   Output (any mix):   --decklink INDEX[,INDEX..] SDI outputs, 1080p59.94; the first sets the pace
//                       --ndi-send NAME            send an NDI stream called NAME
//   With no output the frames are discarded (a pure render-loop test).
//
//   Options: --seconds N  --warmup N  --depth N (SDI queue, default 4)  --report-every N
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
let reportEvery = value(after: "--report-every").flatMap(Double.init) ?? 0

if arguments.contains("--list-decklink") {
    let devices = DeckLinkOutputBridge.listDevices()
    if devices.isEmpty {
        print("No DeckLink devices found. Is Blackmagic Desktop Video installed, the chassis connected,")
        print("and the SDK present in vendor/DeckLinkSDK/include when this was built?")
    }
    for d in devices {
        print("[\(d.index)] \(d.displayName)  (\(d.modelName))  output=\(d.canOutput ? "yes" : "no")  1080p59.94 YUV=\(d.supports1080p5994 ? "yes" : "no")  formats[\(d.ioSupport)]  queryResult=\(d.outputQueryResult)")
    }
    exit(0)
}

if arguments.contains("--ndi-list") {
    do {
        try NDIRuntime.prepare()
    } catch {
        print("NDI unavailable: \(error.localizedDescription)")
        exit(1)
    }
    let wait = value(after: "--wait").flatMap(Double.init) ?? 5.0
    print("Looking for NDI sources for up to \(Int(wait)) s ...")
    let sources = NDIRuntime.findSourcesWaiting(wait)
    if sources.isEmpty { print("No NDI sources found. Is the sender running and on the same network?") }
    for source in sources { print("  \(source.name)   [\(source.address)]") }
    exit(0)
}

let hasInput = arguments.contains("--video") || arguments.contains("--ndi-in")

if hasInput {
    do {
        // Input
        let source: FrameSource
        var ndiInput: NDIFrameSource?
        var inputLabel: String
        if let text = value(after: "--ndi-in") {
            let ndi = try NDIFrameSource(sourceContaining: text, waitSeconds: 10)
            ndiInput = ndi
            source = ndi
            inputLabel = "NDI in: \(ndi.sourceName)"
        } else {
            let videoPath = value(after: "--video") ?? ""
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
            source = try await VideoLoopSource.open(url: URL(fileURLWithPath: videoPath))
            inputLabel = videoPath
        }

        // Outputs: SDI first (it sets the pace), then NDI as a follower. NDI alone is clocked by NDI.
        var hardware: [PacedOutputSink] = []
        if let indexText = value(after: "--decklink") {
            let indexes = indexText.split(separator: ",").compactMap { Int($0) }
            guard !indexes.isEmpty, indexes.count == indexText.split(separator: ",").count else {
                print("--decklink needs device numbers, for example 4 or 4,6 (see --list-decklink)")
                exit(1)
            }
            let depth = value(after: "--depth").flatMap(Int.init) ?? 4
            for index in indexes { hardware.append(try DeckLinkOutputSink(deviceIndex: index, depth: depth)) }
        }
        if let ndiName = value(after: "--ndi-send") {
            hardware.append(try NDIOutputSink(name: ndiName, clocked: hardware.isEmpty))
        }

        let primary: OutputSink = hardware.first ?? NullOutputSink(name: "null", targetFPS: 60)
        let followers = Array(hardware.dropFirst())
        let runner = try SpikeRunner(source: source, output: primary, followers: followers, targetFPS: 60)

        print("StageEngine spike: \(inputLabel)")
        print("  output: \(primary.name)" + followers.map { ", \($0.name)" }.joined())
        print("  \(seconds) s (after \(warmup) s warm-up), 1920x1080")
        let report = try runner.run(seconds: seconds, warmup: warmup, reportEvery: reportEvery)
        print(report)
        if let ndi = ndiInput {
            print("ndi input  : \(ndi.sourceName) \(ndi.resolution), frames received=\(ndi.framesReceived)")
        }
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
