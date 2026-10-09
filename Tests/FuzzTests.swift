import XCTest
@testable import Lumen

/// Throws random and adversarial text at every parser. Nothing may crash, and nothing may take long
/// (a regex that backtracks catastrophically would freeze the app on a live speech transcript).
final class ParserFuzzTests: XCTestCase {
    private static let pieces = ["john", "1 john", "genesis", "ps", "psalm", "chapter", "verse", "3", "16", ":", "-", "–", "thirty", "two", "hundred",
                                 "and", "through", "Verse 1", "[Chorus]", "Bridge", "G", "D/F#", "Em7", "C", "Am", "6m", "1/3", "5(4)", "x2", "|", "(", ")", "[", "]",
                                 "\n", "\n\n", "  ", "\t", "'", "\"", "é", "日本", "🙂", "#", "b", "sus4", "/", "…", "\u{0}", "{", "}", "<", ">", "&"]

    private func randomText(_ rng: inout SplitMix, words: Int) -> String {
        (0..<words).map { _ in Self.pieces[rng.next(Self.pieces.count)] }.joined(separator: rng.next(3) == 0 ? "" : " ")
    }

    private func timed(_ label: String, limit: TimeInterval = 2, _ block: () -> Void) {
        let t = Date(); block()
        let dt = Date().timeIntervalSince(t)
        XCTAssertLessThan(dt, limit, "\(label) took \(dt)s")
    }

    func testRandomTextNeverCrashesAnyParser() {
        var rng = SplitMix(seed: 7)
        for _ in 0..<600 {
            let text = randomText(&rng, words: 1 + rng.next(80))
            _ = LyricParser.sections(from: text)
            _ = LyricParser.presentation(name: "x", text: text, maxLines: 1 + rng.next(4))
            _ = ReferenceParser.parseAll(text)
            _ = SpokenNormalizer.normalize(text)
            var d = ScriptureDetector(); _ = d.scan(text)
            let (t, c) = ChordPro.decode(text); _ = ChordPro.encode(text: t, chords: c)
            _ = try? ChordChartReader.read(text: text, fallbackTitle: "x")
            _ = Chord(text); _ = MusicKey(text)
            for w in text.split(separator: " ").prefix(8) { _ = Nashville.number(for: String(w), key: MusicKey("G")!); _ = Nashville.letter(for: String(w), key: MusicKey("Bb")!) }
            var f = LyricFollower(slides: [text, "a b c", ""]); _ = f.update(heardText: text, current: rng.next(3))
        }
    }

    func testHostileLongInputsStayFast() {
        let long = String(repeating: "john 3:16 ", count: 5000)               // 50k chars
        timed("ReferenceParser long") { _ = ReferenceParser.parseAll(long) }
        timed("Detector long") { var d = ScriptureDetector(); _ = d.scan(long) }
        timed("Normalizer long") { _ = SpokenNormalizer.normalize(String(repeating: "one hundred and twenty ", count: 4000)) }
        timed("Normalizer overflow") { _ = SpokenNormalizer.normalize(String(repeating: "one hundred ", count: 2000)) }
        timed("digits") { _ = ReferenceParser.parseAll(String(repeating: "1 ", count: 20000)) }
        timed("colons") { _ = ReferenceParser.parseAll("gen " + String(repeating: "1:", count: 20000)) }
        timed("books") { _ = ReferenceParser.parseAll(String(repeating: "1 john ", count: 8000)) }
        timed("lyrics long") { _ = LyricParser.presentation(name: "x", text: String(repeating: "Verse 1\nline of words here\n\n", count: 3000), maxLines: 2) }
        timed("headings") { _ = LyricParser.sections(from: String(repeating: "[", count: 30000)) }
        timed("chord line") { _ = try? ChordChartReader.read(text: String(repeating: "G D Em C   ", count: 5000) + "\nwords words", fallbackTitle: "x") }
        timed("chord token") { _ = Chord(String(repeating: "m", count: 40000)); _ = Chord("C" + String(repeating: "7", count: 40000)) }
        timed("ChordPro brackets") { _ = ChordPro.decode(String(repeating: "[G", count: 30000)) }
        timed("follower") {
            var f = LyricFollower(slides: (0..<60).map { _ in String(repeating: "amazing grace how sweet ", count: 20) })
            _ = f.update(heardText: String(repeating: "amazing grace how sweet the sound ", count: 400), current: 3)
        }
        timed("fuzzy match") { _ = ChordMatcher.transfer((0..<200).map { ($0, "G") }, from: String(repeating: "word ", count: 2000), to: String(repeating: "wurd ", count: 2000)) }
    }

    func testNumbersAreNotMistakenForReferencesWithoutABook() {
        var d = ScriptureDetector()
        XCTAssertTrue(d.scan("we need 3 16 oz bottles and 32 chairs").isEmpty)
        XCTAssertTrue(d.scan("the year 1999 was long ago").isEmpty)
    }

    func testPastedLyricsFromRealWorldFormatsParse() {
        // Windows line endings, tabs, smart quotes, ALL-CAPS headings, trailing spaces, chords mixed in
        let text = "AMAZING GRACE\r\n\r\nVERSE 1\r\nAmazing grace, how sweet the sound\t\r\nThat saved a wretch like me  \r\n\r\nCHORUS:\r\n\u{201C}I once was lost\u{201D}\r\n"
        let r = LyricParser.parseTXT(text, fallbackTitle: "x")
        let p = LyricParser.presentation(name: r.title, text: r.lyrics, maxLines: 2)
        XCTAssertEqual(r.title, "AMAZING GRACE")
        XCTAssertEqual(p.groups.map(\.name), ["Verse 1", "Chorus"])
        XCTAssertEqual(p.groups[0].slides[0].text, "Amazing grace, how sweet the sound\nThat saved a wretch like me")
    }

    func testBibleReferenceEdgeCases() {
        XCTAssertNil(ReferenceParser.parse("Psalms 151"))
        XCTAssertEqual(ReferenceParser.parse("Ps 119:176")?.display, "Psalms 119:176")
        XCTAssertEqual(ReferenceParser.parse("Jude 3")?.display, "Jude 1:3", "single-chapter book: the number is the verse")
        XCTAssertEqual(ReferenceParser.parse("3 John 4")?.display, "3 John 1:4")
        var d = ScriptureDetector(); XCTAssertEqual(d.scan("turn with me to Jude 3").first?.reference.display, "Jude 1:3")
        XCTAssertEqual(ReferenceParser.parse("Song of Songs 2:4")?.display, "Song of Songs 2:4")
        XCTAssertEqual(ReferenceParser.parse("Rev 22:21")?.display, "Revelation 22:21")
        XCTAssertNil(ReferenceParser.parse("Genesis 0"))
        XCTAssertNil(ReferenceParser.parse(""))
    }
}
