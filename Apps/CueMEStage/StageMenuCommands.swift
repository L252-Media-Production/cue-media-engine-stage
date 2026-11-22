import SwiftUI
import StageKit

/// Menu bar skeleton. Every live entry sends a `Command`; entries with nothing behind them yet are disabled.
struct StageMenuCommands: Commands {
    let store: StageStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Service") {}.disabled(true)
            Button("Open Service…") {}.disabled(true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Service") {}.disabled(true)
        }
        CommandGroup(replacing: .printItem) {}

        CommandMenu("Show") {
            Button("Next Slide") { store.send(.next) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Slide") { store.send(.previous) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            Button("Clear Slide") { store.send(.clear(.slide)) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Clear Messages") { store.send(.clear(.messages)) }
            Button("Clear All") { store.send(.clear(.all)) }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Button(store.state.blackout ? "End Blackout" : "Blackout") { store.send(.blackout(!store.state.blackout)) }
                .keyboardShortcut("b", modifiers: .command)
            Divider()
            Button("Looks…") {}.disabled(true)
            Button("Messages…") {}.disabled(true)
            Button("Timers…") {}.disabled(true)
        }

        CommandMenu("Audio") {
            let audio = store.state.audio
            Button(audio.transport == .paused ? "Resume" : "Pause") {
                store.send(audio.transport == .paused ? .resumeAudio : .pauseAudio)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(audio.transport != .playing && audio.transport != .paused)
            Button("Fade Out") { store.send(.fadeAudio(seconds: 3)) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(audio.liveTrack == nil)
            Button("Stop") { store.send(.stopAudio) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(audio.liveTrack == nil)
            Divider()
            Button("Skip Next Trigger") { store.send(.skipNextTrigger) }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(audio.nextTrigger == nil)
            Divider()
            Button("Track Settings…") {}.disabled(true)
            Button("Audio Devices…") {}.disabled(true)
        }

        CommandMenu("Output") {
            Button("Screens…") {}.disabled(true)
            Button("Outputs…") {}.disabled(true)
            Button("Stage Display…") {}.disabled(true)
        }

        CommandGroup(before: .toolbar) {
            Button("Operator") {}.disabled(true)
            Button("Editor") {}.disabled(true)
            Divider()
        }
    }
}
