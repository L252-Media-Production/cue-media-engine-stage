import Foundation

extension Library {
    /// A small show for the mock client, previews and tests: two songs, one walk-in track with two
    /// voice-over triggers, one message, one timer, two screens on two SDI outputs.
    public static let sample: Library = {
        let amazing = Song(title: "Amazing Grace", author: "John Newton", slides: [
            Slide(label: "Verse 1", lines: ["Amazing grace, how sweet the sound", "That saved a wretch like me"]),
            Slide(label: "Verse 2", lines: ["'Twas grace that taught my heart to fear", "And grace my fears relieved"]),
            Slide(label: "Verse 3", lines: ["Through many dangers, toils and snares", "I have already come"]),
        ])
        let doxology = Song(title: "Doxology", slides: [
            Slide(label: "Verse", lines: ["Praise God, from whom all blessings flow", "Praise Him, all creatures here below"]),
            Slide(label: "Amen", lines: ["Amen"]),
        ])

        let walkIn = MediaItem(name: "Walk-in loop", kind: .audio, location: "Audio/walk-in.wav", duration: 180)
        let welcome = MediaItem(name: "Welcome VO", kind: .audio, location: "Audio/welcome-vo.wav", duration: 6)
        let reminder = MediaItem(name: "Phones VO", kind: .audio, location: "Audio/phones-vo.wav", duration: 4)

        let walkInSettings = AudioSettings(
            mediaID: walkIn.id, trimIn: 2, trimOut: 170, levelDB: -3, fadeIn: 1, fadeOut: 3,
            triggers: [
                TriggerPoint(at: 30, voiceMediaID: welcome.id, once: true),
                TriggerPoint(at: 90, voiceMediaID: reminder.id),
            ]
        )

        let sdi1 = Output(name: "SDI 1", kind: .sdi, address: "0")
        let sdi2 = Output(name: "SDI 2", kind: .sdi, address: "1")

        let service = Service(name: "Sunday 10:00", items: [
            Item(title: walkIn.name, content: .media(walkIn.id)),
            Item(title: amazing.title, content: .song(amazing.id), slideCount: amazing.slides.count),
            Item(title: "Blank", content: .blank),
            Item(title: doxology.title, content: .song(doxology.id), slideCount: doxology.slides.count),
        ])

        return Library(
            service: service,
            songs: [amazing, doxology],
            media: [walkIn, welcome, reminder],
            audioSettings: [walkIn.id: walkInSettings],
            looks: [Look(name: "Default"), Look(name: "Lower third", fontSize: 48)],
            messages: [Message(text: "Parking lot B: your lights are on")],
            timers: [Timer(name: "Service start", mode: .countdown, duration: 300)],
            screens: [
                Screen(name: "Main", role: .audience, outputID: sdi1.id),
                Screen(name: "Stage", role: .stage, x: 1920, outputID: sdi2.id),
            ],
            outputs: [sdi1, sdi2]
        )
    }()
}
