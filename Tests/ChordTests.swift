import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Lumen

final class ChordTheoryTests: XCTestCase {
    func testParse() {
        let c = Chord("D/F#")!
        XCTAssertEqual(c.root, 2); XCTAssertEqual(c.bass, 6)
        XCTAssertTrue(Chord("Em7")!.isMinor)
        XCTAssertFalse(Chord("Cmaj7")!.isMinor)
        XCTAssertNil(Chord("Amazing"))
        XCTAssertNil(Chord("Be"))
    }

    func testNashville() {
        let g = MusicKey("G")!
        XCTAssertEqual(Nashville.number(for: "G", key: g), "1")
        XCTAssertEqual(Nashville.number(for: "D/F#", key: g), "5/7")
        XCTAssertEqual(Nashville.number(for: "Em7", key: g), "6m7")
        XCTAssertEqual(Nashville.number(for: "Cmaj7", key: g), "4maj7")
        XCTAssertEqual(Nashville.number(for: "Dsus4", key: g), "5sus4")
        XCTAssertEqual(Nashville.number(for: "F", key: g), "b7")
        XCTAssertEqual(Nashville.number(for: "Bb", key: MusicKey("F")!), "4")
        // Minor keys count from the relative major: in Em, Em = 6m, C = 4.
        XCTAssertEqual(Nashville.number(for: "Em", key: MusicKey("Em")!), "6m")
        XCTAssertEqual(Nashville.letter(for: "5/7", key: g), "D/F#")
        XCTAssertEqual(Nashville.letter(for: "4", key: MusicKey("F")!), "Bb")
    }

    func testTransposeAndGuess() {
        XCTAssertEqual(Nashville.transpose("D/F#", by: 2, flats: false), "E/G#")
        XCTAssertEqual(Nashville.transpose("C", by: -2, flats: true), "Bb")
        XCTAssertEqual(Nashville.guessKey(["G", "D", "Em", "C", "G", "D/F#", "G"]), "G")
        XCTAssertEqual(Nashville.guessKey(["Bb", "F", "Gm", "Eb", "Bb"]), "Bb")
    }

    func testChordProRoundTrip() {
        let src = "[G]Amazing [C]grace how [G]sweet the sound\nThat [G]saved a [D]wretch like [G]me"
        let (text, chords) = ChordPro.decode(src)
        XCTAssertEqual(text, "Amazing grace how sweet the sound\nThat saved a wretch like me")
        XCTAssertEqual(chords.count, 6)
        XCTAssertEqual(chords[1], ChordPlacement(line: 0, index: 8, chord: "C"))
        XCTAssertEqual(ChordPro.encode(text: text, chords: chords), src)
    }

    func testSegments() {
        let segs = ChordLayout.segments(line: "Amazing grace", chords: [ChordPlacement(line: 0, index: 0, chord: "G"),
                                                                       ChordPlacement(line: 0, index: 8, chord: "C")])
        XCTAssertEqual(segs, [.init(chord: "G", text: "Amazing "), .init(chord: "C", text: "grace")])
        XCTAssertEqual(ChordLayout.label("D/F#", key: "G", style: .nashville), "5/7")
        XCTAssertEqual(ChordLayout.label("D/F#", key: "G", style: .letters), "D/F#")
    }
}

final class ChordChartReaderTests: XCTestCase {
    let monospaced = """
    Amazing Grace (My Chains Are Gone)
    Key - G  |  Tempo - 64

    VERSE 1
    G                C          G
    Amazing grace how sweet the sound
             G                  D
    That saved a wretch like me

    CHORUS (2x)
    G       C          G
    My chains are gone
    """

    func testMonospacedChart() throws {
        let chart = try ChordChartReader.read(text: monospaced, fallbackTitle: "x")
        XCTAssertEqual(chart.title, "Amazing Grace (My Chains Are Gone)")
        XCTAssertEqual(chart.key, "G")
        XCTAssertEqual(chart.sections.map(\.name), ["Verse 1", "Chorus"])
        let l1 = chart.sections[0].lines[0]
        XCTAssertEqual(l1.lyric, "Amazing grace how sweet the sound")
        XCTAssertEqual(l1.chords.map(\.chord), ["G", "C", "G"])
        XCTAssertEqual(l1.chords.map(\.index), [0, 18, 28])   // "A", "s"(weet), "s"(ound)
        let l2 = chart.sections[0].lines[1]
        XCTAssertEqual(l2.chords.map(\.index), [9, 27])        // "d" of saved; D comes after "me" (held)
    }

    func testChordProChart() throws {
        let chart = try ChordChartReader.read(text: "{title: Test}\n{key: D}\n{soc}\n[D]Holy [G]holy\n{eoc}", fallbackTitle: "x")
        XCTAssertEqual(chart.key, "D")
        XCTAssertEqual(chart.sections.first?.name, "Chorus")
        XCTAssertEqual(chart.sections.first?.lines.first?.chords.map(\.index), [0, 5])
    }

    func testMatcherPlacesChordsOnSlidesWithDifferentLineBreaks() throws {
        let chart = try ChordChartReader.read(text: monospaced, fallbackTitle: "x")
        var p = LyricParser.presentation(name: "Amazing Grace", text: """
            [Verse 1]
            Amazing grace how sweet the sound
            That saved a wretch like me

            [Chorus]
            My chains are gone
            """, maxLines: 2)
        let report = ChordMatcher.apply(chart, to: &p, maxLines: 2)
        XCTAssertEqual(report.matchedLines, 3)
        XCTAssertEqual(p.key, "G")
        let v1 = p.groups[0].slides[0]
        XCTAssertEqual(ChordPro.encode(text: v1.text, chords: v1.chords ?? []).components(separatedBy: "\n")[0],
                       "[G]Amazing grace how [C]sweet the [G]sound")
    }

    func testTransferAcrossWordingChanges() {
        // Chart says "Amazing grace how sweet the sound", slide drops "how".
        let moved = ChordMatcher.transfer([(0, "G"), (18, "C"), (28, "G")],
                                          from: "Amazing grace how sweet the sound", to: "Amazing grace, sweet the sound")
        XCTAssertEqual(moved.map(\.0), [0, 15, 25])
    }

    func testBuildsSongFromChartWhenEmpty() throws {
        let chart = try ChordChartReader.read(text: monospaced, fallbackTitle: "x")
        var p = Presentation(name: "New Song", kind: .song)
        ChordMatcher.apply(chart, to: &p, maxLines: 2)
        XCTAssertEqual(p.name, "Amazing Grace (My Chains Are Gone)")
        XCTAssertEqual(p.groups.map(\.name), ["Verse 1", "Chorus"])
        XCTAssertNotNil(p.groups[1].slides[0].chords)
    }

    /// A real PDF in a proportional font, two columns, chords drawn over the exact syllable x positions.
    func testProportionalTwoColumnPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let lyricFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let chordFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)

        func draw(_ s: String, _ font: CTFont, x: CGFloat, y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        func offset(_ s: String, _ i: Int) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: lyricFont]))
            return CTLineGetOffsetForStringIndex(line, i, nil)
        }
        func chorded(_ lyric: String, _ chords: [(Int, String)], x: CGFloat, y: CGFloat) {
            for (i, c) in chords { draw(c, chordFont, x: x + offset(lyric, i), y: y + 14) }
            draw(lyric, lyricFont, x: x, y: y)
        }
        draw("Cornerstone", CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil), x: 40, y: 740)
        draw("Key - C  Tempo - 72", lyricFont, x: 40, y: 720)
        // Left column
        draw("VERSE 1", chordFont, x: 40, y: 680)
        chorded("My hope is built on nothing less", [(0, "C"), (17, "F"), (25, "C")], x: 40, y: 650)
        chorded("Than Jesus' blood and righteousness", [(0, "Am"), (11, "G"), (21, "F")], x: 40, y: 620)
        // Right column
        draw("CHORUS", chordFont, x: 330, y: 680)
        chorded("Christ alone, Cornerstone", [(0, "C"), (13, "G/B")], x: 330, y: 650)
        chorded("Weak made strong in the Saviour's love", [(0, "Am"), (17, "F"), (32, "C")], x: 330, y: 620)
        ctx.endPDFPage()
        ctx.closePDF()

        let chart = try ChordChartReader.read(url: url)
        XCTAssertEqual(chart.key, "C")
        XCTAssertEqual(chart.sections.map(\.name), ["Verse 1", "Chorus"])
        let v = chart.sections[0].lines
        XCTAssertEqual(v[0].lyric, "My hope is built on nothing less")
        XCTAssertEqual(v[0].chords.map(\.index), [0, 17, 25])
        XCTAssertEqual(v[1].chords.map(\.chord), ["Am", "G", "F"])
        XCTAssertEqual(v[1].chords.map(\.index), [0, 12, 22])  // "blood", "righteousness"
        let c = chart.sections[1].lines
        XCTAssertEqual(c[0].lyric, "Christ alone, Cornerstone")
        XCTAssertEqual(c[0].chords.map(\.index), [0, 14])  // "Cornerstone"
        XCTAssertEqual(c[1].chords.map(\.index), [0, 17, 32])
        XCTAssertEqual(Nashville.number(for: c[0].chords[1].chord, key: MusicKey(chart.key!)!), "5/7")
    }

    /// Mirrors a PraiseCharts "Numbers" 2-column chart: number chords, "ho - ly" syllables,
    /// chords held after a word, page headers repeated, copyright footer, and a roadmap line.
    func testNumbersChartWithSyllablesAndFooter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nums-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let lyricFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let boldFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        func width(_ s: String, _ f: CTFont) -> CGFloat {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f])), nil, nil, nil)
        }
        func draw(_ s: String, _ font: CTFont, x: CGFloat, y: CGFloat) {
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font])), ctx)
        }
        /// Lyric pieces with an optional chord; chords may also float `after` a piece.
        func line(_ parts: [(String, String?)], y: CGFloat, x0: CGFloat = 40, after: [(Int, String, CGFloat)] = []) {
            var x = x0
            var starts: [CGFloat] = []
            for (text, chord) in parts {
                starts.append(x)
                if let chord { draw(chord, boldFont, x: x, y: y + 14) }
                draw(text, lyricFont, x: x, y: y)
                x += width(text, lyricFont)
            }
            for (i, chord, dx) in after { draw(chord, boldFont, x: starts[i] + width(parts[i].0, lyricFont) + dx, y: y + 14) }
        }
        func header() {
            draw("Test Song", CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil), x: 40, y: 742)
            draw("www.example.com/123", lyricFont, x: 40, y: 712)
            draw("Key: Numbers \u{00B7} Time: 4/4", lyricFont, x: 330, y: 712)
            draw("Test Artist", lyricFont, x: 40, y: 700)
        }
        ctx.beginPDFPage(nil)
        header()
        draw("Chorus 1", boldFont, x: 40, y: 660)
        line([("And the angels ", nil), ("cry, ", "4"), ("ho  ", "6m"), ("-  ", nil), ("ly", "5")], y: 630)
        line([("Holy for - ", nil), ("ever", "1")], y: 600, after: [(1, "1sus", 14), (1, "1", 44)])
        draw("Verse 2", boldFont, x: 40, y: 560)
        line([("And if you've been re - ", nil), ("deemed", "1")], y: 530)
        draw("Pre-Chorus 1 > Chorus 1 >", boldFont, x: 330, y: 660)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        header()
        draw("Tag", boldFont, x: 40, y: 660)
        line([("We'll ", nil), ("sing the song for - ", "6m"), ("ever", "5")], y: 630)
        draw("\u{00A9} 2026 Some Publisher (Admin by Someone)", lyricFont, x: 40, y: 590)
        draw("Music Group. CCLI Song No. 123. Unauthorized distribution", lyricFont, x: 40, y: 578)
        ctx.endPDFPage()
        ctx.closePDF()

        let chart = try ChordChartReader.read(url: url)
        XCTAssertNil(chart.key, "a Numbers chart has no letter key")
        XCTAssertEqual(chart.title, "Test Song")
        XCTAssertEqual(chart.roadmap, ["Pre-Chorus 1", "Chorus 1"])
        XCTAssertEqual(chart.sections.map(\.name), ["Chorus 1", "Verse 2", "Tag"])
        func cp(_ l: ChordChart.Line) -> String {
            ChordPro.encode(text: l.lyric, chords: l.chords.map { ChordPlacement(line: 0, index: $0.index, chord: $0.chord) })
        }
        XCTAssertEqual(cp(chart.sections[0].lines[0]), "And the angels [4]cry, [6m]ho[5]ly")
        XCTAssertEqual(cp(chart.sections[0].lines[1]), "Holy for[1]ever[1sus][1]")
        XCTAssertEqual(cp(chart.sections[1].lines[0]), "And if you've been re[1]deemed")
        XCTAssertEqual(chart.sections[2].lines.count, 1, "page header and copyright must not become lyrics")
        XCTAssertEqual(cp(chart.sections[2].lines[0]), "We'll [6m]sing the song for[5]ever")

        // Numbers display as-is with no key; with a key, letters can be shown.
        XCTAssertEqual(ChordLayout.label("6m", key: nil, style: .nashville), "6m")
        XCTAssertEqual(ChordLayout.label("1/3", key: "G", style: .letters), "G/B")
        XCTAssertEqual(ChordLayout.label("6m", key: "G", style: .both), "6m Em")
    }
}
