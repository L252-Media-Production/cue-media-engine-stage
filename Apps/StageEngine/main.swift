import Dispatch
import Foundation
import Engine
import Metal

// StageEngine: the output process.
//
// Usage:
//   StageEngine [--seconds N]                      time a bare 60 Hz clock (no video, no GPU)
//   StageEngine --list-decklink                    list the DeckLink devices the driver sees
//   StageEngine --ndi-list [--wait N]              list NDI sources on the network
//
//   Input (pick one):   --video FILE               a looping video file
//                       --ndi-in TEXT [--ndi-raw]  the NDI source whose name contains TEXT
//                                                  (frame-synced to our output; --ndi-raw skips that)
//                       --sdi-in INDEX             capture SDI on a DeckLink connector set to Input
//                                                  (1080p, 4:2:2); --sdi-buffer N frames of jitter queue (default 2)
//   Output (any mix):   --decklink INDEX[,INDEX..] SDI outputs, 1080p59.94; the first sets the pace
//                       --ndi-send NAME            send an NDI stream called NAME
//   With no output the frames are discarded (a pure render-loop test).
//
//   Canvas test:  --canvas WxH --decklink A,B,C [--screens "x,y,w,h;x,y,w,h;..."] [--video FILE] [--no-pattern]
//                 [--screen-text] [--no-master 2,3]
//     Renders one big canvas (for example 5760x1080 or 6000x1920) and sends a 1920x1080 screen cut from it
//     to every SDI output (the first output sets the pace). Without --screens the screens sit side by side
//     from the left edge. A test pattern (grid, numbered borders, frame counters, a bar sweeping across the
//     whole canvas) is drawn over the optional --video, which is scaled to cover the canvas (the master).
//     --screen-text gives every screen its own text layer (on top of the master); --no-master 2 switches
//     the master off on screen 2, so it shows only its own layers.
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
        print("[\(d.index)] \(d.displayName)  (\(d.modelName))  output=\(d.canOutput ? "yes" : "no")  input=\(d.canInput ? "yes" : "no")  1080p59.94 YUV=\(d.supports1080p5994 ? "yes" : "no")  formats[\(d.ioSupport)]  queryResult=\(d.outputQueryResult)")
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

if let canvasText = value(after: "--canvas") {
    do {
        let parts = canvasText.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 64, parts[1] >= 64, parts[0] <= 16384, parts[1] <= 16384 else {
            print("--canvas needs a size such as 5760x1080 or 6000x1920")
            exit(1)
        }
        let canvasW = parts[0], canvasH = parts[1]
        guard let indexText = value(after: "--decklink") else {
            print("--canvas needs --decklink with one index per screen, for example --decklink 4,0")
            exit(1)
        }
        let indexes = indexText.split(separator: ",").compactMap { Int($0) }
        guard !indexes.isEmpty, indexes.count == indexText.split(separator: ",").count else {
            print("--decklink needs device numbers, for example 4,0 (see --list-decklink)")
            exit(1)
        }

        var screens: [ScreenRegion] = []
        if let text = value(after: "--screens") {
            for entry in text.split(separator: ";") {
                let n = entry.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard n.count == 4, n[2] > 0, n[3] > 0, n[0] >= 0, n[1] >= 0,
                      n[0] + n[2] <= canvasW, n[1] + n[3] <= canvasH else {
                    print("Bad screen \"\(entry)\": use x,y,w,h inside the \(canvasW)x\(canvasH) canvas")
                    exit(1)
                }
                screens.append(ScreenRegion(x: n[0], y: n[1], width: n[2], height: n[3]))
            }
        } else {
            for i in 0..<indexes.count {
                guard (i + 1) * 1920 <= canvasW, 1080 <= canvasH else {
                    print("The \(canvasW)x\(canvasH) canvas has no room for \(indexes.count) screens of 1920x1080 side by side. Pass --screens.")
                    exit(1)
                }
                screens.append(ScreenRegion(x: i * 1920, y: 0, width: 1920, height: 1080))
            }
        }
        guard screens.count == indexes.count else {
            print("\(screens.count) screens but \(indexes.count) outputs: they must match.")
            exit(1)
        }

        // Master composition: an optional video covering the whole canvas, and the test pattern.
        var master: [CompositionLayer] = []
        if let videoPath = value(after: "--video") {
            guard FileManager.default.isReadableFile(atPath: videoPath) else {
                print("Cannot open \(videoPath) (see the note about protected folders in the usage text).")
                exit(1)
            }
            let video = try await VideoLoopSource.open(url: URL(fileURLWithPath: videoPath))
            master.append(CompositionLayer(name: "Background", content: .video(video), fit: .cover))
        }
        if !arguments.contains("--no-pattern") {
            master.append(CompositionLayer(name: "Test pattern", content: .pattern))
        }

        // One composition per screen. --no-master 2,3 turns the master off on those screens (1-based);
        // --screen-text adds a text layer to every screen that shows the screen number and time.
        let noMaster = Set((value(after: "--no-master") ?? "").split(separator: ",").compactMap { Int($0) })
        let wantText = arguments.contains("--screen-text")
        let device = MTLCreateSystemDefaultDevice()
        var screenTexts: [TextLayer] = []
        var screenComps: [ScreenComposition] = []
        for (i, region) in screens.enumerated() {
            var layers: [CompositionLayer] = []
            if wantText, let device {
                let text = try TextLayer(device: device, width: region.width, height: region.height)
                screenTexts.append(text)
                layers.append(CompositionLayer(name: "Slides", content: .text(text)))
            }
            screenComps.append(ScreenComposition(name: "Screen \(i + 1)", region: region,
                                                 showMaster: !noMaster.contains(i + 1), layers: layers))
        }

        let depth = value(after: "--depth").flatMap(Int.init) ?? 6
        var sinks: [PacedOutputSink] = []
        for index in indexes { sinks.append(try DeckLinkOutputSink(deviceIndex: index, depth: depth)) }

        let runner = try CanvasRunner(canvasWidth: canvasW, canvasHeight: canvasH, master: master,
                                      screens: screenComps, sinks: sinks)
        if !screenTexts.isEmpty {
            let texts = screenTexts
            runner.willRender = { _, t in
                for (i, text) in texts.enumerated() {
                    text.update([TextLine(text: "SCREEN \(i + 1)", fontSize: 140, centerYFromTop: 480),
                                 TextLine(text: "t = \(Int(t)) s", fontSize: 64, centerYFromTop: 620)])
                }
            }
        }
        print("StageEngine canvas: \(canvasW)x\(canvasH) (\(String(format: "%.1f", Double(canvasW * canvasH) / 1_000_000)) MP), background: \(value(after: "--video") ?? "none")")
        for (i, screen) in screenComps.enumerated() {
            print("  screen \(i + 1): \(screen.region) -> \(sinks[i].name)" + (screen.showMaster ? "" : "  (master off)"))
        }
        print("  \(seconds) s (after \(warmup) s warm-up)")
        let report = try runner.run(seconds: seconds, warmup: warmup, reportEvery: reportEvery)
        print(report)
    } catch {
        print("StageEngine canvas failed: \(error.localizedDescription)")
        print("  (\(error))")
        exit(1)
    }
    exit(0)
}

let hasInput = arguments.contains("--video") || arguments.contains("--ndi-in") || arguments.contains("--sdi-in")

if hasInput {
    do {
        // Input
        let source: FrameSource
        var ndiInput: NDIFrameSource?
        var sdiInput: SDIFrameSource?
        var inputLabel: String
        if let indexText = value(after: "--sdi-in") {
            guard let index = Int(indexText) else {
                print("--sdi-in needs a device number (see --list-decklink, input=yes)")
                exit(1)
            }
            let sdi = try SDIFrameSource(deviceIndex: index, buffer: value(after: "--sdi-buffer").flatMap(Int.init) ?? 2)
            sdiInput = sdi
            source = sdi
            inputLabel = "SDI in: \(sdi.deviceName) (index \(index))"
        } else if let text = value(after: "--ndi-in") {
            let ndi = try NDIFrameSource(sourceContaining: text, waitSeconds: 10,
                                         frameSync: !arguments.contains("--ndi-raw"))
            ndiInput = ndi
            source = ndi
            inputLabel = "NDI in: \(ndi.sourceName)" + (ndi.frameSync ? " (frame-synced)" : " (raw)")
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
        if let sdi = sdiInput {
            print("sdi input  : \(sdi.captureSummary)")
            print("sdi cadence: \(sdi.cadenceSummary)")
            print("sdi        : \(sdi.conversionSummary)")
            print("sdi latency: \(sdi.stampSummary)")
        }
        if let ndi = ndiInput {
            print("ndi input  : \(ndi.sourceName) \(ndi.resolution), frames received=\(ndi.framesReceived)")
            print("ndi cadence: \(ndi.cadenceSummary)")
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
