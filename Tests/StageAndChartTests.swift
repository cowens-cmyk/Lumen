import AppKit
import CoreImage
import PDFKit
import SwiftUI
import XCTest
@testable import Lumen

@MainActor
final class StageTemplateTests: XCTestCase {
    private func make() -> (LiveEngine, LibraryStore) {
        let store = LibraryStore(folder: tempFolder())
        let engine = LiveEngine(store: store)
        engine.media = MediaEngine()
        engine.capture = CaptureManager(); engine.browser = BrowserController()
        engine.ndiIn = NDIReceiveManager(); engine.midi = MIDIManager()
        return (engine, store)
    }

    private func presentation(_ name: String, _ kind: PresentationKind, slides n: Int = 2) -> Presentation {
        var p = Presentation(name: name, kind: kind)
        p.groups = [SlideGroup(name: "Verse 1", color: .black, slides: (1...n).map { Slide(text: "\(name) line \($0)") })]
        return p
    }

    private var sermonTimerLayout: (LibraryStore) -> StageLayout? = { $0.data.stageLayouts.first { $0.style == .timers } }

    func testBuiltInTemplates() throws {
        let (_, store) = make()
        let worship = try XCTUnwrap(store.data.stageLayouts.first { $0.name == "Worship Team" })
        XCTAssertEqual(worship.currentColor.hex, "#FACC15", "current lyrics are yellow")
        XCTAssertEqual(worship.nextColor.hex, "#FFFFFF", "next slide is white")
        XCTAssertEqual(worship.footer, true)
        XCTAssertNotEqual(worship.showKey, false)
        let timer = try XCTUnwrap(sermonTimerLayout(store))
        XCTAssertFalse(timer.timerIDs.isEmpty, "the sermon timer is on the timer template")
        XCTAssertEqual(store.data.settings.stageLayoutByKind["sermon"], timer.id)
    }

    func testPresentationTypeDefaultsPutTheStageLayoutUpAutomatically() throws {
        let (engine, store) = make()
        let sermon = presentation("Sermon", .sermon), song = presentation("Song", .song)
        store.upsert(sermon); store.upsert(song)
        let timer = try XCTUnwrap(sermonTimerLayout(store))
        engine.trigger(sermon, index: 0)
        XCTAssertEqual(engine.stageLayoutOverride, timer.id)
        engine.trigger(sermon, index: 1)
        XCTAssertEqual(engine.stageLayoutOverride, timer.id)
        engine.trigger(song, index: 0)
        XCTAssertNil(engine.stageLayoutOverride, "a type with no default goes back to the screen's own layout")
    }

    func testSlideActionSetsAndResetsLayoutAndAnOverrideSurvivesSlidesInThePresentation() async throws {
        let (engine, store) = make()
        let target = StageLayout(name: "Special")
        store.data.stageLayouts.append(target)
        var p = presentation("Talk", .generic, slides: 3)
        p.groups[0].slides[0].actions = [.setStageLayout(target.id)]
        store.upsert(p)
        engine.trigger(p, index: 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.stageLayoutOverride, target.id)
        engine.trigger(p, index: 1)
        XCTAssertEqual(engine.stageLayoutOverride, target.id, "moving between slides doesn't undo it")
        await engine.perform([.resetStageLayout])
        XCTAssertNil(engine.stageLayoutOverride)
    }

    func testDeletedLayoutNeverBlanksTheStage() {
        let (engine, _) = make()
        engine.setStageLayout(UUID())
        XCTAssertNil(engine.stageLayoutOverride)
    }

    func testClearAllReturnsToTheDefaultLayout() throws {
        let (engine, store) = make()
        engine.setStageLayout(try XCTUnwrap(sermonTimerLayout(store)).id)
        XCTAssertNotNil(engine.stageLayoutOverride)
        engine.clear(.all)
        XCTAssertNil(engine.stageLayoutOverride)
    }

    func testTypeDefaultActionsRunOnEnteringNotOnEverySlide() async throws {
        let (engine, store) = make()
        let timer = try XCTUnwrap(store.data.timers.first { $0.name == "Sermon" })
        store.data.settings.actionsByKind["sermon"] = [.startTimer(timer.id)]
        let sermon = presentation("Sermon", .sermon, slides: 3)
        store.upsert(sermon)
        engine.trigger(sermon, index: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.timers[timer.id]?.running, true, "sermon timer started by the type default")
        engine.stopTimer(timer.id)
        engine.trigger(sermon, index: 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.timers[timer.id]?.running, false, "the next slide must not restart it")
    }

    func testStageSnapshotFollowsTheOverride() throws {
        let app = AppModel(libraryFolder: tempFolder())
        let screen = try XCTUnwrap(app.store.data.screens.first { $0.role == .stage })
        XCTAssertNotEqual(app.outputs.stageSnapshot(for: screen).layout.style, .timers)
        let timer = try XCTUnwrap(app.store.data.stageLayouts.first { $0.style == .timers })
        app.engine.setStageLayout(timer.id)
        let snap = app.outputs.stageSnapshot(for: screen)
        XCTAssertEqual(snap.layout.style, .timers)
        XCTAssertFalse(snap.timers.isEmpty)
        let json = RemoteAPI.stage(app)
        XCTAssertEqual(json["bigTimers"] as? Bool, true)
    }

    func testOlderLibraryGetsTheNewTemplatesButCustomLooksAreKept() throws {
        let folder = tempFolder()
        let store = LibraryStore(folder: folder)
        var old = StageLayout(name: "Worship Team")
        old.currentColor = .white; old.nextColor = RGBA(hex: "#FACC15"); old.footer = nil; old.showKey = nil
        var custom = StageLayout(name: "My Custom")
        custom.currentColor = .white; custom.nextColor = RGBA(hex: "#FACC15")
        store.data.stageLayouts = [old, custom]
        store.data.settings.stageTemplatesVersion = nil
        store.data.settings.stageLayoutByKind = [:]
        store.saveNow()

        let reloaded = LibraryStore(folder: folder)
        let w = try XCTUnwrap(reloaded.data.stageLayouts.first { $0.name == "Worship Team" })
        XCTAssertEqual(w.currentColor.hex, "#FACC15"); XCTAssertEqual(w.nextColor.hex, "#FFFFFF"); XCTAssertEqual(w.footer, true)
        let c = try XCTUnwrap(reloaded.data.stageLayouts.first { $0.name == "My Custom" })
        XCTAssertEqual(c.currentColor.hex, "#FFFFFF", "layouts the church made themselves are not restyled")
        XCTAssertNil(c.footer)
        XCTAssertNotNil(reloaded.data.stageLayouts.first { $0.style == .timers })
        XCTAssertNotNil(reloaded.data.settings.stageLayoutByKind["sermon"])
        // Running it again must not add another copy.
        reloaded.saveNow()
        let again = LibraryStore(folder: folder)
        XCTAssertEqual(again.data.stageLayouts.filter { $0.style == .timers }.count, 1)
    }

    func testNewActionsSurviveSavingAndLoading() throws {
        let data = try JSONEncoder().encode([SlideAction.setStageLayout(UUID()), .resetStageLayout])
        let back = try JSONDecoder().decode([SlideAction].self, from: data)
        XCTAssertEqual(back.count, 2)
        // A settings file from before these settings existed still loads.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"remotePort": 9000}"#.utf8))
        XCTAssertEqual(old.remotePort, 9000)
        XCTAssertTrue(old.stageLayoutByKind.isEmpty)
    }

    // MARK: rendering

    private func cgImage(_ ci: CIImage) -> CGImage? { CIContext().createCGImage(ci, from: ci.extent) }

    private func pixels(_ img: CGImage) -> [(r: Int, g: Int, b: Int, y: Int)] {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<(w * h)).map { (Int(data[$0 * 4]), Int(data[$0 * 4 + 1]), Int(data[$0 * 4 + 2]), $0 / w) }
    }

    func testWorshipStageShowsYellowCurrentWhiteNextAndAFooter() throws {
        var layout = StageLayout.worship()
        layout.showChords = false
        let snap = StageSnapshot(layout: layout, current: "Holy forever", next: "Lamb of God", key: "G",
                                 nextGroup: "Chorus", notes: "", clock: "10:42:07", timers: [], message: nil)
        let ci = try XCTUnwrap(Snapshot.render(StageCanvas(s: snap), size: CGSize(width: 960, height: 540), opaque: true))
        let img = try XCTUnwrap(cgImage(ci))
        let px = pixels(img)
        let h = img.height
        // Rows count from the bottom in this buffer, so work in thirds either way up.
        func count(_ test: (Int, Int, Int) -> Bool, rows: Range<Int>) -> Int { px.filter { rows.contains($0.y) && test($0.r, $0.g, $0.b) }.count }
        let yellow: (Int, Int, Int) -> Bool = { $0 > 220 && $1 > 170 && $2 < 90 }
        let white: (Int, Int, Int) -> Bool = { $0 > 235 && $1 > 235 && $2 > 235 }
        XCTAssertGreaterThan(count(yellow, rows: 0..<h), 200, "current lyrics are yellow")
        XCTAssertGreaterThan(count(white, rows: 0..<h), 200, "next lyrics, key and time are white")
        // The footer strip is lighter than the black background along one edge of the picture.
        func edgeBrightness(_ rows: Range<Int>) -> Double {
            let sel = px.filter { rows.contains($0.y) }
            return Double(sel.reduce(0) { $0 + $1.r + $1.g + $1.b }) / Double(max(1, sel.count) * 765)
        }
        let a = edgeBrightness(0..<20), b = edgeBrightness((h - 20)..<h)
        XCTAssertGreaterThan(max(a, b), 0.08, "there is a footer bar")
    }

    func testBigTimerTemplateRenders() throws {
        let snap = StageSnapshot(layout: StageLayout.sermonTimer(), current: "", next: "", nextGroup: "", notes: "Wrap up by 11:45",
                                 clock: "10:42:07", timers: [("Sermon", "-1:30")], message: nil)
        let ci = try XCTUnwrap(Snapshot.render(StageCanvas(s: snap), size: CGSize(width: 960, height: 540), opaque: true))
        let img = try XCTUnwrap(cgImage(ci))
        let red = pixels(img).filter { $0.r > 200 && $0.g < 80 && $0.b < 80 }.count
        XCTAssertGreaterThan(red, 500, "an overrun timer is big and red")
    }
}

// MARK: - Chord chart → song

@MainActor
final class ChartSongTests: XCTestCase {
    private func line(_ lyric: String) -> ChordChart.Line { .init(lyric: lyric, chords: [(index: 0, chord: "G")]) }

    private var chart: ChordChart {
        ChordChart(title: "Test Song", key: "G", roadmap: [], sections: [
            .init(name: "Verse 1", lines: [line("Amazing grace how sweet the sound"), line("That saved a wretch like me")]),
            .init(name: "Chorus", lines: [line("My chains are gone I have been set free"), line("My God my Savior has ransomed me")]),
            .init(name: "Verse 2", lines: [line("Through many dangers toils and snares"), line("I have already come")]),
            .init(name: "Chorus", lines: [line("My chains are gone I have been set free"), line("My God my Savior has ransomed me")]),
        ])
    }

    private func order(_ p: Presentation) -> [String] {
        p.arrangement.compactMap { id in p.groups.first { $0.id == id }?.name }
    }

    func testSongBuiltFromChartHasLyricsKeyChordsAndRepeatedChorus() {
        var p = Presentation(name: "", kind: .song)
        let r = ChordMatcher.apply(chart, to: &p, maxLines: 2)
        XCTAssertEqual(p.name, "Test Song")
        XCTAssertEqual(p.key, "G")
        XCTAssertEqual(p.groups.map(\.name), ["Verse 1", "Chorus", "Verse 2"])
        XCTAssertEqual(order(p), ["Verse 1", "Chorus", "Verse 2", "Chorus"], "the chorus plays twice, as the chart prints it")
        XCTAssertEqual(p.orderedSlides.count, 4)
        XCTAssertNotNil(p.groups[0].slides[0].chords)
        XCTAssertEqual(r.orderCount, 4)
    }

    func testPrintedRoadmapWins() {
        var c = chart
        c.roadmap = ["Verse 1", "Chorus", "Verse 2", "Chorus", "Chorus"]
        var p = Presentation(name: "", kind: .song)
        ChordMatcher.apply(c, to: &p, maxLines: 2)
        XCTAssertEqual(order(p), ["Verse 1", "Chorus", "Verse 2", "Chorus", "Chorus"])
    }

    func testOrderCanBeLeftAloneAndPCOSongsAreProtectedWhenItChanges() {
        var p = Presentation(name: "", kind: .song)
        ChordMatcher.apply(chart, to: &p, maxLines: 2, applyOrder: false)
        XCTAssertTrue(p.arrangement.isEmpty)

        var pco = Presentation(name: "Synced", kind: .song)
        pco.pcoSongID = "123"
        ChordMatcher.apply(chart, to: &pco, maxLines: 2)
        XCTAssertTrue(pco.lockedFromSync, "otherwise the next Planning Center sync would erase the chart's order")
    }

    func testReplaceLyricsRebuildsAnExistingSong() {
        var p = LyricParser.presentation(name: "Old", text: "[Verse 1]\nSome other words\nEntirely different", maxLines: 2)
        ChordMatcher.apply(chart, to: &p, maxLines: 2)
        XCTAssertEqual(p.groups.first?.slides.first?.text, "Some other words\nEntirely different", "default keeps your words")
        ChordMatcher.apply(chart, to: &p, maxLines: 2, replaceLyrics: true)
        XCTAssertEqual(p.groups.first { $0.name == "Verse 1" }?.slides.first?.text, "Amazing grace how sweet the sound\nThat saved a wretch like me")
    }

    // MARK: a real PDF

    private func chartPDF(chords: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("song-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        func draw(_ s: String, _ f: CTFont, x: CGFloat, y: CGFloat) {
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f])), ctx)
        }
        draw("Test Song", CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil), x: 40, y: 750)
        draw("Key - G", font, x: 40, y: 730)
        var y: CGFloat = 690
        let sections: [(String, [String])] = [
            ("VERSE 1", ["Amazing grace how sweet the sound", "That saved a wretch like me"]),
            ("CHORUS", ["My chains are gone I have been set free", "My God my Savior has ransomed me"]),
            ("VERSE 2", ["Through many dangers toils and snares", "I have already come"]),
            ("CHORUS", ["My chains are gone I have been set free", "My God my Savior has ransomed me"]),
        ]
        for (name, lines) in sections {
            draw(name, bold, x: 40, y: y); y -= 34
            for l in lines {
                if chords { draw("G", bold, x: 40, y: y + 14); draw("C", bold, x: 40 + 120, y: y + 14); draw("D", bold, x: 40 + 200, y: y + 14) }
                draw(l, font, x: 40, y: y); y -= 34
            }
            y -= 12
        }
        ctx.endPDFPage(); ctx.closePDF()
        return url
    }

    func testChordChartPDFsAreRecognisedAndSlideDecksAreNot() throws {
        XCTAssertTrue(ChordChartReader.looksLikeChart(url: try chartPDF()))

        let prose = FileManager.default.temporaryDirectory.appendingPathComponent("prose-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(prose as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (i, s) in ["Welcome to Hope Church", "A new series starts this Sunday", "Baptism is next month", "Sign up at the welcome desk"].enumerated() {
            ctx.textPosition = CGPoint(x: 40, y: 700 - CGFloat(i) * 30)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font])), ctx)
        }
        ctx.endPDFPage(); ctx.closePDF()
        XCTAssertFalse(ChordChartReader.looksLikeChart(url: prose))
    }

    func testDroppingAChartPDFCreatesAFullSong() async throws {
        let store = LibraryStore(folder: tempFolder())
        let url = try chartPDF()
        let result = try await Importer(store: store).importFiles([url])
        let p = try XCTUnwrap(result.presentations.first)
        XCTAssertEqual(p.kind, .song)
        XCTAssertEqual(p.name, "Test Song")
        XCTAssertEqual(p.key, "G")
        XCTAssertEqual(p.groups.map(\.name), ["Verse 1", "Chorus", "Verse 2"])
        XCTAssertEqual(p.arrangement.count, 4, "verse, chorus, verse, chorus")
        XCTAssertEqual(p.orderedSlides.map(\.groupName), ["Verse 1", "Chorus", "Verse 2", "Chorus"])
        XCTAssertTrue(p.orderedSlides.allSatisfy { $0.slide.chords != nil }, "chords are on every slide")
        XCTAssertNotNil(store.presentation(p.id), "it is saved in the library")
    }
}
