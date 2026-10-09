import Foundation

/// A sensible first-run setup: themes per kind, three screens, and looks for a typical church livestream.
enum SeedData {
    static func make() -> LibraryData {
        var d = LibraryData()

        let worship = Theme(name: "Worship Lyrics", fontName: "Helvetica Neue", fontSize: 76, bold: true,
                            uppercase: false, maxLinesPerSlide: 2)
        var scripture = Theme(name: "Scripture", fontName: "Georgia", fontSize: 58, bold: false,
                              align: .leading, vAlign: .middle, padding: 140, showLabel: true, maxLinesPerSlide: 6)
        scripture.lowerThird.accentColor = RGBA(hex: "#38BDF8")
        scripture.lowerThird.fontSize = 38
        var sermon = Theme(name: "Sermon Points", fontName: "Avenir Next", fontSize: 70, bold: true, maxLinesPerSlide: 4)
        sermon.background = RGBA(hex: "#0F172A")
        let announce = Theme(name: "Announcements", fontName: "Avenir Next", fontSize: 64, bold: true, maxLinesPerSlide: 6)
        var bibleLT = Theme(name: "Bible Lower Third", fontName: "Georgia", fontSize: 40, bold: false, align: .leading,
                            showLabel: true)
        bibleLT.lowerThird.accentColor = RGBA(hex: "#38BDF8")
        bibleLT.lowerThird.fontSize = 36
        var lyricLT = Theme(name: "Lyrics Lower Third", fontSize: 44, bold: true)
        lyricLT.lowerThird.align = .center
        lyricLT.lowerThird.fontSize = 54
        lyricLT.lowerThird.showReference = false
        d.themes = [worship, scripture, sermon, announce, bibleLT, lyricLT]

        d.settings.defaultThemeByKind = [
            .song: worship.id, .scripture: scripture.id, .sermon: sermon.id,
            .announcement: announce.id, .media: worship.id, .generic: worship.id,
        ]

        let stage = StageLayout(name: "Worship Team")
        let speaker = StageLayout(name: "Speaker", showNext: true, showNotes: true)
        d.stageLayouts = [stage, speaker]

        let audience = Screen(name: "Audience", role: .audience, destinations: [.window])
        let stream = Screen(name: "Livestream", role: .stream, destinations: [])
        var stageScreen = Screen(name: "Stage", role: .stage, destinations: [])
        stageScreen.stageLayoutID = stage.id
        d.screens = [audience, stream, stageScreen]

        // Normal service: audience gets full slides; stream gets lyric/Bible lower thirds over the camera.
        var normal = Look(name: "Service")
        normal.screens[audience.id] = ScreenLookConfig()
        normal.screens[stream.id] = ScreenLookConfig(
            layers: LayerSet(background: false, slide: true, props: true, messages: false, liveVideo: false),
            defaultMode: .lowerThird,
            modeByKind: [.sermon: .fullSlide, .announcement: .fullSlide, .media: .fullSlide],
            themeByKind: [.scripture: bibleLT.id, .song: lyricLT.id])

        // Takeover: the stream shows exactly what the room sees.
        var takeover = Look(name: "Stream Takeover")
        takeover.screens[audience.id] = ScreenLookConfig()
        takeover.screens[stream.id] = ScreenLookConfig(defaultMode: .fullSlide)

        // Camera only: stream is clean.
        var clean = Look(name: "Clean Stream")
        clean.screens[audience.id] = ScreenLookConfig()
        clean.screens[stream.id] = ScreenLookConfig(
            layers: LayerSet(background: false, slide: false, props: true, messages: false, liveVideo: false),
            defaultMode: .hidden)
        d.looks = [normal, takeover, clean]
        d.settings.defaultLookID = normal.id

        d.timers = [
            ServiceTimer(name: "Service Countdown", kind: .countdownTo(hour: 10, minute: 30)),
            ServiceTimer(name: "Sermon", kind: .countdown(seconds: 35 * 60)),
            ServiceTimer(name: "Elapsed", kind: .elapsed),
        ]
        d.stageLayouts[0].timerIDs = [d.timers[0].id]
        d.stageLayouts[1].timerIDs = [d.timers[1].id]

        d.props = [
            Prop(name: "Speaker Name", kind: .lowerThird, title: "Pastor Name", subtitle: "Lead Pastor", autoHideSeconds: 8),
            Prop(name: "Give Online", kind: .lowerThird, title: "Give Online", subtitle: "hopejc.org/give"),
        ]

        d.macros = [
            Macro(name: "Walk In", color: RGBA(hex: "#22C55E"), symbol: "figure.walk",
                  actions: [.clear(.slide), .setLook(normal.id), .startTimer(d.timers[0].id)]),
            Macro(name: "Sermon Start", color: RGBA(hex: "#F59E0B"), symbol: "mic.fill",
                  actions: [.setLook(takeover.id), .resetTimer(d.timers[1].id), .startTimer(d.timers[1].id),
                            .showProp(d.props[0].id),
                            .sendMIDI(MIDIMessage(kind: .noteOn, channel: 1, number: 60, value: 127))]),
            Macro(name: "Camera Only", color: RGBA(hex: "#64748B"), symbol: "video.fill",
                  actions: [.setLook(clean.id)]),
            Macro(name: "Clear All", color: RGBA(hex: "#EF4444"), symbol: "xmark.circle.fill",
                  actions: [.clear(.all), .stopSlideshow]),
        ]

        d.templates = [ServiceTemplate(name: "Sunday Service")]
        d.settings.pcoTemplateID = d.templates[0].id

        d.presentations = [
            LyricParser.presentation(name: "Welcome", kind: .announcement, text: """
                [Welcome]
                Welcome to Hope Church
                We're glad you're here
                """),
            Presentation(name: "Announcements", kind: .announcement),
            Presentation(name: "Sermon", kind: .sermon),
        ]
        return d
    }
}
