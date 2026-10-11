import AppKit
import CoreText
import XCTest
@testable import Lumen

/// Draws chord-chart PDFs laid out the way MultiTracks and PraiseCharts lay theirs out (lyrics invented here, since
/// real charts are licensed): circled section badges and a roadmap with repeat counts, superscript chord
/// extensions, grey performance notes, two columns with sections running from one column (and page) into the next,
/// words split around chords, headings that mean "repeat this", and jump lines.
final class ChartPDF {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString).pdf")
    private var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let ctx: CGContext
    static let body: CGFloat = 13.6, small: CGFloat = 10.2

    init() { ctx = CGContext(url as CFURL, mediaBox: &box, nil)! }
    func page() { ctx.beginPDFPage(nil) }
    func endPage() { ctx.endPDFPage() }
    func close() -> URL { ctx.closePDF(); return url }

    func width(_ s: String, _ size: CGFloat) -> CGFloat {
        CTLineGetTypographicBounds(line(s, size, gray: false), nil, nil, nil)
    }
    private func line(_ s: String, _ size: CGFloat, gray: Bool) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
        attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = gray ? CGColor(gray: 0.57, alpha: 1) : CGColor(gray: 0, alpha: 1)
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }
    @discardableResult
    func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat = ChartPDF.body, gray: Bool = false) -> CGFloat {
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line(s, size, gray: gray), ctx)
        return x + width(s, size)
    }
    /// A chord like "6m^7" or "1^2/3": the part after ^ (up to a slash) is drawn as a smaller superscript.
    func chord(_ spec: String, x: CGFloat, y: CGFloat, raise: CGFloat = 0) {
        let parts = spec.components(separatedBy: "^")
        var cx = text(parts[0], x: x, y: y)
        if parts.count > 1 {
            let rest = parts[1]
            let sup = rest.prefix { $0 != "/" }, after = rest.drop { $0 != "/" }
            cx = text(String(sup), x: cx, y: y + raise, size: ChartPDF.small)
            if !after.isEmpty { text(String(after), x: cx, y: y) }
        }
    }
    /// Lyric pieces, each with an optional chord above it; `gap` adds space before a piece (a word split for a chord).
    func lyric(_ pieces: [(text: String, chord: String?, gap: CGFloat)], x: CGFloat, y: CGFloat) {
        var cx = x
        for p in pieces {
            cx += p.gap
            if let c = p.chord { chord(c, x: cx, y: y + 14) }
            cx = text(p.text, x: cx, y: y)
        }
    }
    func heading(badge: String, _ name: String, x: CGFloat, y: CGFloat) {
        text(badge, x: x + 4, y: y, size: ChartPDF.small)
        text(name, x: x + 22, y: y, size: 14.8)
    }
}

@MainActor
final class ChartFormatTests: XCTestCase {
    func order(_ p: Presentation) -> [String] { p.arrangement.compactMap { id in p.groups.first { $0.id == id }?.name } }
    func group(_ p: Presentation, _ name: String) -> SlideGroup? { p.groups.first { $0.name == name } }
    func chords(_ g: SlideGroup?) -> [String] { (g?.slides ?? []).flatMap { ($0.chords ?? []).map(\.chord) } }
    func lyrics(_ p: Presentation) -> String { p.groups.flatMap { $0.slides.map(\.text) }.joined(separator: "\n") }

    // MARK: MultiTracks

    private func multiTracksChart() -> URL {
        let pdf = ChartPDF()
        pdf.page()
        pdf.text("A Very Long Test Song Title Here", x: 69, y: 724, size: 23)
        pdf.text("Page: 1/2", x: 515, y: 721, size: 10)
        pdf.text("Test Writer", x: 69, y: 707, size: 11, gray: true)
        pdf.text("Key: G  Tempo: 72  Time: 4/4", x: 424, y: 707, size: 10)
        // Roadmap: I C1 C2 Rf² C1 Vp B³ O, the repeat counts small and raised.
        var x: CGFloat = 77
        for (badge, count) in [("I", nil), ("C1", nil), ("C2", nil), ("Rf", "2"), ("C1", nil), ("Vp", nil), ("B", "3"), ("O", nil)] as [(String, String?)] {
            let end = pdf.text(badge, x: x, y: 678, size: ChartPDF.small)
            if let count { pdf.text(count, x: end, y: 686, size: 7.9) }
            x += 30
        }
        // Left column
        pdf.heading(badge: "I", "INTRO", x: 72, y: 642)
        pdf.text("Piano only", x: 180, y: 628, size: 12.5, gray: true)
        pdf.chord("1", x: 69, y: 612); pdf.chord("4^sus2", x: 100, y: 612); pdf.chord("5", x: 150, y: 612)
        pdf.heading(badge: "C1", "CHORUS 1", x: 72, y: 575)
        pdf.lyric([("Holy is the ", nil, 0), ("Lord ", "1", 0), ("on high", "6m^7", 0)], x: 69, y: 539)
        pdf.lyric([("Through the generatio", nil, 0), ("ns", "1/3", 6)], x: 69, y: 511)
        pdf.lyric([("We are go", "5", 0), ("ing home", "4^2", 7)], x: 69, y: 483)
        pdf.lyric([("We won't f", nil, 0), (" - ", nil, 0), ("a- ", "5", 0), ("il", "4", 0)], x: 69, y: 455)
        pdf.heading(badge: "C2", "CHORUS 2", x: 72, y: 418)
        pdf.text("A little bigger", x: 180, y: 404, size: 12.5, gray: true)
        pdf.lyric([("Higher than ", nil, 0), ("the mountains", "4", 0)], x: 69, y: 380)
        pdf.lyric([("Deeper than ", nil, 0), ("the sea", "5^sus4", 0)], x: 69, y: 352)
        // Right column: Chorus 2 carries on, then repeats are printed out in full.
        pdf.lyric([("Wider than ", nil, 0), ("the sky", "1", 0)], x: 330, y: 640)
        for (i, y) in [600.0, 520.0].enumerated() {
            pdf.heading(badge: "Rf", "REFRAIN", x: 333, y: y)
            if i == 1 { pdf.text("Build", x: 470, y: y - 14, size: 12.5, gray: true) }
            pdf.lyric([("Sing it ", nil, 0), ("out", "1", 0)], x: 330, y: y - 36)
            pdf.lyric([("Sing it ", nil, 0), ("loud", "5^6", 0)], x: 330, y: y - 64)
        }
        pdf.heading(badge: "C1", "CHORUS 1", x: 333, y: 440)
        pdf.lyric([("Holy is the ", nil, 0), ("Lord ", "1", 0), ("on high", "6m^7", 0)], x: 330, y: 404)
        pdf.lyric([("Through the generatio", nil, 0), ("ns", "1/3", 6)], x: 330, y: 376)
        pdf.lyric([("We are go", "5", 0), ("ing home", "4^2", 7)], x: 330, y: 348)
        pdf.lyric([("We won't f", nil, 0), (" - ", nil, 0), ("a- ", "5", 0), ("il", "4", 0)], x: 330, y: 320)
        pdf.heading(badge: "Vp", "VAMP", x: 333, y: 280)
        pdf.text("1 bar Vamp", x: 470, y: 266, size: 12.5, gray: true)
        pdf.endPage()

        pdf.page()
        pdf.text("A Very Long Test Song Title Here", x: 69, y: 740, size: 16)
        pdf.text("Page: 2/2", x: 515, y: 740, size: 10)
        for (i, y) in [690.0, 600.0, 510.0].enumerated() {
            pdf.heading(badge: "B", "BRIDGE", x: 72, y: y)
            if i == 2 { pdf.text("Keep building", x: 180, y: y - 14, size: 12.5, gray: true) }
            pdf.lyric([("The ", nil, 0), ("rain came down", "4", 0)], x: 69, y: y - 36)
            pdf.lyric([("But my ", "1^2/3", 0), ("house stood strong", nil, 0)], x: 69, y: y - 64)
        }
        pdf.heading(badge: "O", "OUTRO", x: 333, y: 690)
        pdf.lyric([("We won't ", nil, 0), ("fail", "1", 0)], x: 330, y: 654)
        pdf.text("a product of MultiTracks.com", x: 160, y: 60, size: 9)
        pdf.text("Writers: Test Writer", x: 400, y: 70, size: 9)
        pdf.text("\u{00A9} \u{2117} 2026 Test Records // mtID: 1", x: 400, y: 58, size: 9)
        pdf.endPage()
        return pdf.close()
    }

    func testMultiTracksChart() throws {
        let url = multiTracksChart()
        XCTAssertTrue(ChordChartReader.looksLikeChart(url: url))
        let chart = try ChordChartReader.read(url: url)
        XCTAssertEqual(chart.title, "A Very Long Test Song Title Here", "the page number beside the title isn't part of it")
        XCTAssertEqual(chart.artist, "Test Writer")
        XCTAssertEqual(chart.key, "G")
        XCTAssertEqual(chart.roadmap, ["Intro", "Chorus 1", "Chorus 2", "Refrain", "Refrain", "Chorus 1", "Vamp",
                                       "Bridge", "Bridge", "Bridge", "Outro"], "badges expand, and Rf² / B³ repeat")

        var p = Presentation(name: "", kind: .song)
        ChordMatcher.apply(chart, to: &p, maxLines: 2)
        XCTAssertEqual(p.groups.map(\.name), ["Intro", "Chorus 1", "Chorus 2", "Refrain", "Vamp", "Bridge", "Outro"],
                       "sections printed again reuse their group")
        XCTAssertEqual(order(p), chart.roadmap)

        // Lyrics: words put back together, nothing from the page furniture.
        let words = lyrics(p)
        for good in ["Through the generations", "We are going home", "We won't fail", "Wider than the sky"] {
            XCTAssertTrue(words.contains(good), "missing “\(good)” in:\n\(words)")
        }
        for bad in ["Page", "MultiTracks", "Writers", "Records", "Title Here", "Piano only", "INTRO", "sus2"] {
            XCTAssertFalse(words.contains(bad), "“\(bad)” leaked into the lyrics:\n\(words)")
        }
        XCTAssertEqual(group(p, "Chorus 2")?.slides.map(\.text), ["Higher than the mountains\nDeeper than the sea", "Wider than the sky"],
                       "a section carries on into the next column")

        // Chords, superscripts included.
        XCTAssertEqual(group(p, "Intro")?.slides.map(\.text), [""], "an instrumental is a blank slide for the room")
        XCTAssertEqual(chords(group(p, "Intro")), ["1", "4sus2", "5"])
        XCTAssertEqual(chords(group(p, "Chorus 1")), ["1", "6m7", "1/3", "5", "4(2)", "5", "4"])
        XCTAssertEqual(chords(group(p, "Refrain")), ["1", "5(6)"])
        XCTAssertEqual(chords(group(p, "Bridge")), ["4", "1(2)/3"])
        XCTAssertEqual(chords(group(p, "Chorus 2")), ["4", "5sus4", "1"])

        // Notes go to the band, not the screen.
        XCTAssertEqual(group(p, "Intro")?.slides.first?.notes, "Piano only")
        XCTAssertEqual(group(p, "Chorus 2")?.slides.first?.notes, "A little bigger")
        XCTAssertEqual(group(p, "Vamp")?.slides.first?.notes, "1 bar Vamp")
        XCTAssertEqual(p.key, "G")
        XCTAssertEqual(p.author, "Test Writer")
    }

    // MARK: PraiseCharts

    private func praiseChartsChart() -> URL {
        let pdf = ChartPDF()
        func header(_ page: Int) {
            pdf.text("Test Anthem", x: 49, y: 742, size: 30)
            pdf.text("www.praisecharts.com/123", x: 49, y: 712, size: 11)
            pdf.text("Key: Numbers \u{00B7} Time: 4/4", x: 444, y: 712, size: 11)
            pdf.text("Test Artist", x: 49, y: 700, size: 11)
            pdf.text("Page \(page) of 2", x: 510, y: 700, size: 11)
        }
        pdf.page()
        header(1)
        pdf.text("Intro", x: 49, y: 660)
        pdf.text("4  /  /  6m  |  5  /  /  /", x: 49, y: 642)
        pdf.text("Verse 1", x: 49, y: 610)
        pdf.lyric([("A ", nil, 0), ("thousand voices ", "1", 0), ("rising up", "4", 0)], x: 49, y: 580)
        pdf.lyric([("To ", nil, 0), ("sing the song of ", "6m", 0), ("ages", "5(4)", 0)], x: 49, y: 552)
        pdf.text("Chorus 1", x: 49, y: 516)
        pdf.lyric([("And the angels ", nil, 0), ("cry, ", "4", 0), ("ho - ", "6m", 0), ("ly", "5", 0)], x: 49, y: 486)
        pdf.lyric([("Holy for - ", nil, 0), ("ever", "1", 0)], x: 49, y: 458)
        pdf.text("Verse 2", x: 49, y: 422)
        pdf.lyric([("If you've been ", nil, 0), ("forgiven", "1", 0)], x: 49, y: 392)
        // Right column: Verse 2 continues, then an empty heading (sing Chorus 1 again) and a jump line wrapped onto two rows.
        pdf.lyric([("And if you've been re - ", nil, 0), ("deemed", "4", 0)], x: 310, y: 640)
        pdf.text("Chorus 1", x: 310, y: 604)
        pdf.text("Chorus 2", x: 310, y: 578)
        pdf.lyric([("Hear your peo - ", nil, 0), ("ple sing", "1/3", 0)], x: 310, y: 548)
        pdf.lyric([("To the King of ", nil, 0), ("Kings", "2m", 0)], x: 310, y: 520)
        pdf.text("Bridge", x: 310, y: 484)
        pdf.lyric([("You will ", nil, 0), ("always be", "4", 0)], x: 310, y: 454)
        pdf.text("Chorus 1  >  Chorus 2  >", x: 310, y: 418)
        pdf.text("Bridge", x: 310, y: 400)
        pdf.endPage()
        pdf.page()
        header(2)
        pdf.text("Tag", x: 49, y: 660)
        pdf.lyric([("We'll ", nil, 0), ("sing for - ", "6m", 0), ("ever", "5", 0)], x: 49, y: 630)
        pdf.text("\u{00A9} 2026 Test Publishing. CCLI Song No. 1234567. CCLI No.", x: 49, y: 590, size: 9)
        pdf.text("7654321. Unauthorized distribution is prohibited.", x: 49, y: 578, size: 9)
        pdf.endPage()
        return pdf.close()
    }

    func testPraiseChartsChart() throws {
        let chart = try ChordChartReader.read(url: praiseChartsChart())
        XCTAssertEqual(chart.title, "Test Anthem")
        XCTAssertEqual(chart.artist, "Test Artist")
        XCTAssertNil(chart.key, "“Key: Numbers” isn't a key")
        XCTAssertEqual(chart.ccli, "1234567")
        XCTAssertTrue(chart.roadmap.isEmpty, "a jump line partway through isn't the whole song order")

        var p = Presentation(name: "", kind: .song)
        ChordMatcher.apply(chart, to: &p, maxLines: 2)
        XCTAssertEqual(p.groups.map(\.name), ["Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Bridge", "Tag"])
        XCTAssertEqual(order(p), ["Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 1", "Chorus 2", "Bridge",
                                  "Chorus 1", "Chorus 2", "Bridge", "Tag"])
        XCTAssertEqual(group(p, "Verse 2")?.slides.map(\.text), ["If you've been forgiven\nAnd if you've been redeemed"])
        XCTAssertEqual(group(p, "Chorus 1")?.slides.map(\.text), ["And the angels cry, holy\nHoly forever"])
        XCTAssertEqual(chords(group(p, "Intro")), ["4", "6m", "5"])
        XCTAssertEqual(chords(group(p, "Verse 1")), ["1", "4", "6m", "5(4)"])
        XCTAssertEqual(p.ccli, "1234567")
        XCTAssertNil(p.key)
        XCTAssertFalse(lyrics(p).contains("Test Anthem"))
        XCTAssertFalse(lyrics(p).contains("CCLI"))
    }

    // MARK: Pieces

    func testSuperscriptChordText() {
        XCTAssertEqual(ChordChartReader.chordText([("6m", false), ("7", true)]), "6m7")
        XCTAssertEqual(ChordChartReader.chordText([("5", false), ("6", true)]), "5(6)")
        XCTAssertEqual(ChordChartReader.chordText([("4", false), ("2", true), ("/6", false)]), "4(2)/6")
        XCTAssertEqual(ChordChartReader.chordText([("1", false), ("maj7", true), ("/3", false)]), "1maj7/3")
        XCTAssertEqual(ChordChartReader.chordText([("1", false), ("sus4", true)]), "1sus4")
        XCTAssertEqual(ChordChartReader.chordText([("G", false), ("2", true)]), "G2")
        XCTAssertEqual(ChordChartReader.chordText([("Em", false), ("7", true)]), "Em7")
        for c in ["6m7", "5(6)", "4(2)/6", "1maj7/3", "1(2)/3", "5add4", "4sus2"] { XCTAssertTrue(Chord.isRealChord(c), c) }
        XCTAssertEqual(ChordLayout.label("5(6)", key: "G", style: .letters), "D(6)")
    }

    func testSyllablesRejoinWithoutGluingRealWords() {
        let dictionary: Set<String> = ["going", "go", "generations", "generation", "fail", "holy", "forever", "for", "ever",
                                       "under", "shaken", "the", "we", "are", "home", "firm", "foundation", "in", "jesus", "amen", "a", "men"]
        let isWord = { (w: String) in dictionary.contains(w.lowercased()) }
        func join(_ s: String) -> String { ChordChartReader.joinSyllables(s, [], isWord: isWord).text }
        XCTAssertEqual(join("We are go ing home"), "We are going home")
        XCTAssertEqual(join("Through generatio ns"), "Through generations")
        XCTAssertEqual(join("Through generation s"), "Through generations")
        XCTAssertEqual(join("He won't f - -a- - il"), "He won't fail")
        XCTAssertEqual(join("So I won't be go ing un - der"), "So I won't be going under")
        XCTAssertEqual(join("is sha- ken"), "is shaken")
        XCTAssertEqual(join("Holy for - ever and a - men"), "Holy forever and amen")
        XCTAssertEqual(join("my firm foundation"), "my firm foundation", "two words stay two words")
        XCTAssertEqual(join("in Jesus"), "in Jesus")
        // Chords move with the letters: a chord on the removed gap lands on the next syllable.
        let r = ChordChartReader.joinSyllables("go ing home", [(index: 3, chord: "4"), (index: 7, chord: "5")], isWord: isWord)
        XCTAssertEqual(r.text, "going home")
        XCTAssertEqual(r.chords.map(\.index), [2, 6])
    }

    func testRealDictionaryJoinsCommonSplits() {
        XCTAssertTrue(SpellCheck.isWord("going"))
        XCTAssertFalse(SpellCheck.isWord("generatio"))
        XCTAssertEqual(ChordChartReader.joinSyllables("So I won't be go ing un - der", []).text, "So I won't be going under")
        XCTAssertEqual(ChordChartReader.joinSyllables("He's faithful through generatio ns", []).text, "He's faithful through generations")
    }

    func testPlanningCenterSongsKeepTheirOwnOrder() throws {
        var p = LyricParser.presentation(name: "Synced", text: "[Verse 1]\nHoly is the Lord on high\n\n[Chorus 1]\nAnd the angels cry holy", maxLines: 2)
        p.pcoSongID = "42"
        let pcoOrder = p.arrangement
        let chart = ChordChart(title: "Synced", key: "G", roadmap: ["Chorus 1", "Verse 1", "Chorus 1"], sections: [
            .init(name: "Verse 1", lines: [.init(lyric: "Holy is the Lord on high", chords: [(index: 0, chord: "G")])]),
            .init(name: "Chorus 1", lines: [.init(lyric: "And the angels cry holy", chords: [(index: 0, chord: "C")])]),
        ])
        ChordMatcher.apply(chart, to: &p, maxLines: 2, applyOrder: false)   // what Planning Center sync does
        XCTAssertEqual(p.arrangement, pcoOrder)
        XCTAssertFalse(p.lockedFromSync)
        XCTAssertNotNil(p.groups[0].slides[0].chords)
    }
}
