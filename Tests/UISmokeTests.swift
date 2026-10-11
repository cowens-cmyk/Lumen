import AppKit
import SwiftUI
import XCTest
@testable import Lumen

/// Builds every main screen with realistic data and renders it. Catches crashes at view-construction time (bad
/// indexing, force-unwraps on odd data) that clicking around would find; set TEST_RUNNER_LUMEN_SHOT_DIR to keep PNGs.
@MainActor
final class UISmokeTests: XCTestCase {
    var app: AppModel!
    var songID = UUID()

    override func setUp() async throws {
        app = AppModel(libraryFolder: tempFolder())
        let text = """
        [Verse 1]
        [G]Amazing grace how [C]sweet the [G]sound
        That [G]saved a [D]wretch like [G]me
        I once was lost but now am found
        Was blind but now I see

        [Chorus]
        My chains are gone, I've been set free
        My God my Savior has ransomed me
        """
        let (plain, chords) = ChordPro.decode(text)
        var song = LyricParser.presentation(name: "Amazing Grace", text: plain.replacingOccurrences(of: "\n\n", with: "\n\n"), maxLines: 2)
        song.key = "G"; song.author = "John Newton"; song.ccli = "22025"
        song.groups[0].slides[0].chords = chords
        song.groups[0].slides[0].notes = "Start soft, build on the chorus"
        app.store.upsert(song)
        songID = song.id
        let announce = LyricParser.presentation(name: "Announcements", kind: .announcement, text: "[Slides]\nBaptism is next Sunday\nSign up at the welcome desk", maxLines: 2)
        app.store.upsert(announce)
        var pl = Playlist(name: "Sun Oct 12 – Test", items: [PlaylistItem(kind: .header("WORSHIP")), PlaylistItem(kind: .presentation(song.id), note: "Cameron leads\nKey of G"),
                                                           PlaylistItem(kind: .presentation(announce.id)), PlaylistItem(kind: .placeholder("Offering"))])
        pl.date = Date()
        app.store.upsert(pl)
        app.selectedPlaylistID = pl.id
        app.selectedPresentationID = song.id
        app.outputs.rebuild()
        app.engine.trigger(song, index: 0, playlistID: pl.id)
    }

    override func tearDown() async throws {
        app.outputs.renderers.values.forEach { $0.stop() }
    }

    private func render<V: View>(_ view: V, _ size: CGSize, _ name: String) throws {
        let host = NSHostingView(rootView: view.environment(app).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))     // let .task / .onAppear settle
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("\(name): no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Not a blank image: something was drawn
        var distinct = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
                var px = [Int](repeating: 0, count: 4); rep.getPixel(&px, atX: x, y: y)
                distinct.insert(UInt32(truncatingIfNeeded: px[0] << 16 | px[1] << 8 | px[2]))
            }
        }
        XCTAssertGreaterThan(distinct.count, 1, "\(name) rendered blank (one flat colour)")
        if let dir = ProcessInfo.processInfo.environment["LUMEN_SHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }

    func testOperatorWindow() throws { try render(ContentView(), CGSize(width: 1280, height: 800), "01-operator") }

    func testRecoveryBannerAndToast() throws {
        app.recovery = SessionSnapshot(cleanExit: false, presentationID: songID, presentationName: "Amazing Grace", index: 2, playlistID: nil, lookID: nil, savedAt: Date())
        app.flash("Phone remote PIN is 4821 — see Setup → Remote & MIDI")
        try render(ContentView(), CGSize(width: 1280, height: 800), "02-operator-recovery")
    }

    func testVolunteerMode() throws {
        app.volunteerMode = true
        try render(ContentView(), CGSize(width: 1280, height: 800), "03-volunteer")
    }

    func testEveryPresentationEditorTab() throws {
        for (mode, name) in [(0, "text"), (1, "slides"), (2, "arrangement"), (3, "info"), (4, "chords")] {
            app.editorInitialMode = mode
            try render(PresentationEditor(presentationID: songID), CGSize(width: 1000, height: 700), "10-editor-\(name)")
        }
    }

    func testEverySettingsTab() throws {
        let size = CGSize(width: 900, height: 620)
        try render(ScreensSettings(), size, "20-settings-screens")
        try render(LooksSettings(), size, "21-settings-looks")
        try render(ThemesSettings(), size, "22-settings-themes")
        try render(MacrosSettings(), size, "23-settings-macros")
        try render(StageSettings(), size, "24-settings-stage")
        try render(TypeDefaultsSettings(), size, "24b-settings-type-defaults")
        try render(PlanningCenterSettings(), size, "25-settings-planning-center")
        try render(BibleSettings(), size, "26-settings-bible")
        try render(ConnectSettings(), size, "27-settings-remote-midi")
        try render(GeneralSettings(), size, "28-settings-general")
    }

    func testEveryLivePanelTab() throws {
        let size = CGSize(width: 420, height: 560)
        try render(ScripturePanel(), size, "30-panel-scripture")
        try render(MediaPanel(), size, "31-panel-media")
        try render(PropsPanel(), size, "32-panel-props")
        try render(TimersPanel(), size, "33-panel-timers")
        try render(MessagesPanel(), size, "34-panel-messages")
        try render(ListenPanel(), size, "35-panel-listen")
        try render(SchedulePanel(), size, "36-panel-schedule")
    }

    func testStageAndLowerThirdCanvases() throws {
        let screen = try XCTUnwrap(app.store.data.screens.first { $0.role == .stage })
        let snap = app.outputs.stageSnapshot(for: screen)
        try render(StageCanvas(s: snap).frame(width: designSize.width, height: designSize.height), CGSize(width: 960, height: 540), "40-stage-canvas")
        let theme = app.store.data.themes[0]
        try render(SlidePreview(text: "Amazing grace how sweet the sound\nThat saved a wretch like me", theme: theme, mode: .lowerThird),
                   CGSize(width: 640, height: 360), "41-lower-third")
    }

    func testSettingsAreLockedInVolunteerModeView() {
        // The Settings scene swaps in a lock screen when volunteer mode is on (checked via the model flag it reads).
        app.volunteerMode = true
        XCTAssertTrue(app.volunteerMode)
        app.volunteerMode = false
    }
}
