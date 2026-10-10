import AppKit
import SwiftUI
import XCTest
@testable import Lumen

@MainActor
final class ScriptureSlidesTests: XCTestCase {
    // KJV (public domain) — Genesis 30:33-36, the passage in the ProPresenter screenshot, and one very long verse.
    let gen30: [BibleVerse] = [
        BibleVerse(chapter: 30, number: 33, text: "So shall my righteousness answer for me in time to come, when it shall come for my hire before thy face: every one that is not speckled and spotted among the goats, and brown among the sheep, that shall be counted stolen with me."),
        BibleVerse(chapter: 30, number: 34, text: "And Laban said, Behold, I would it might be according to thy word."),
        BibleVerse(chapter: 30, number: 35, text: "And he removed that day the he goats that were ringstraked and spotted, and all the she goats that were speckled and spotted, and every one that had some white in it, and all the brown among the sheep, and gave them into the hand of his sons."),
        BibleVerse(chapter: 30, number: 36, text: "And he set three days' journey betwixt himself and Jacob: and Jacob fed the rest of Laban's flocks."),
    ]
    let esther89 = BibleVerse(chapter: 8, number: 9, text: "Then were the king's scribes called at that time in the third month, that is, the month Sivan, on the three and twentieth day thereof; and it was written according to all that Mordecai commanded unto the Jews, and to the lieutenants, and the deputies and rulers of the provinces which are from India unto Ethiopia, an hundred twenty and seven provinces, unto every province according to the writing thereof, and unto every people after their language, and to the Jews according to their writing, and according to their language.")

    private func ref(_ s: String) -> BibleReference { ReferenceParser.parse(s)! }

    /// What a slide must start with: the marker of its first verse.
    private func marker(_ v: BibleVerse) -> String { ScriptureService.superscript(v.number) + " " }

    /// Slides hold the verse as cleaned for display (trimmed, line breaks removed).
    private func shown(_ v: BibleVerse) -> String { BibleText.forSlide(v.text, keepLineBreaks: false) }

    private func versesIn(_ slide: Slide, of verses: [BibleVerse]) -> [BibleVerse] {
        verses.filter { slide.text.contains(marker($0) + shown($0)) }
    }

    /// The rule: every slide begins at the start of a verse, every verse appears whole exactly once, in order.
    private func assertWholeVerseSlides(_ p: Presentation, _ verses: [BibleVerse], _ ctx: String, file: StaticString = #filePath, line: UInt = #line) {
        let slides = p.orderedSlides.map(\.slide)
        var seen: [Int] = []
        for (i, s) in slides.enumerated() {
            let inside = versesIn(s, of: verses)
            XCTAssertFalse(inside.isEmpty, "\(ctx): slide \(i) holds no whole verse", file: file, line: line)
            if let first = inside.first { XCTAssertTrue(s.text.hasPrefix(marker(first)), "\(ctx): slide \(i) doesn't start at a verse boundary: \(s.text.prefix(40))", file: file, line: line) }
            // Nothing but whole verses: the slide text is exactly those verses joined.
            XCTAssertEqual(s.text, inside.map { marker($0) + shown($0) }.joined(separator: " "), "\(ctx): slide \(i) has partial text", file: file, line: line)
            seen += inside.map(\.number)
        }
        XCTAssertEqual(seen, verses.map(\.number), "\(ctx): every verse exactly once, in order", file: file, line: line)
    }

    func testLongVerseStaysWholeOnItsOwnSlide() {
        let short = BibleVerse(chapter: 1, number: 1, text: "Short verse.")
        let verses = [short, BibleVerse(chapter: 1, number: 2, text: String(repeating: "word ", count: 200)), BibleVerse(chapter: 1, number: 3, text: "Another short one.")]
        let p = ScriptureService.build(ref: ref("Genesis 1:1-3"), verses: verses, abbreviation: "KJV", versesPerSlide: 3, maxChars: 260)
        XCTAssertEqual(p.orderedSlides.count, 3, "the long verse isn't glued to its neighbours and isn't split")
        assertWholeVerseSlides(p, verses, "long")
        XCTAssertTrue(p.orderedSlides[1].slide.text.contains(shown(verses[1])), "all of it, on one slide")
    }

    func testVerseThatDoesNotFitMovesWholeToTheNextSlide() {
        // Three 100-char verses with room for ~250 chars: verses 1+2 share a slide; verse 3 starts the next, intact.
        let v = (1...3).map { BibleVerse(chapter: 5, number: $0, text: String(repeating: "x", count: 99) + ".") }
        let p = ScriptureService.build(ref: ref("Genesis 5:1-3"), verses: v, abbreviation: "ESV", versesPerSlide: 5, maxChars: 250)
        XCTAssertEqual(p.orderedSlides.map { versesIn($0.slide, of: v).map(\.number) }, [[1, 2], [3]])
        XCTAssertEqual(p.orderedSlides.map(\.slide.label), ["Genesis 5:1-2 ESV", "Genesis 5:3 ESV"], "each slide's reference matches its verses")
        assertWholeVerseSlides(p, v, "move")
    }

    func testGenesis30FromTheScreenshot() {
        let p = ScriptureService.build(ref: ref("Genesis 30:33-36"), verses: gen30, abbreviation: "KJV", versesPerSlide: 4, maxChars: 300)
        assertWholeVerseSlides(p, gen30, "gen30")
        XCTAssertGreaterThan(p.orderedSlides.count, 1)
        // Verse 35 is long: it must start its own slide rather than trailing off the previous one.
        XCTAssertTrue(p.orderedSlides.contains { $0.slide.text.hasPrefix(marker(gen30[2])) })
    }

    func testRealThemeLayoutDecidesTheBreaks() throws {
        let store = LibraryStore(folder: tempFolder())
        let theme = store.resolvedTheme(for: Presentation(name: "", kind: .scripture))
        let fits = ScriptureService.fitTest(theme: theme)
        XCTAssertTrue(fits("¹ For God so loved the world, that he gave his only begotten Son."), "a short verse fits")
        XCTAssertFalse(fits(String(repeating: "and it came to pass ", count: 60)), "a wall of text doesn't")
        var big = theme; big.fontSize = 120
        XCTAssertFalse(ScriptureService.fitTest(theme: big)("¹ For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life."),
                       "a bigger font means less fits, so the breaks move")
        let p = ScriptureService.build(ref: ref("Genesis 30:33-36"), verses: gen30, abbreviation: "KJV", versesPerSlide: 4, maxChars: 900, fits: fits)
        assertWholeVerseSlides(p, gen30, "theme")
        XCTAssertGreaterThan(p.orderedSlides.count, 1, "all four verses don't fit one 58pt slide")
        for s in p.orderedSlides { XCTAssertTrue(fits(s.slide.text) || versesIn(s.slide, of: gen30).count == 1, "a multi-verse slide must fit") }
    }

    func testPropertyAnyVerseLengthsAnySettings() {
        var rng = SplitMix(seed: 99)
        for round in 0..<400 {
            let n = 1 + rng.next(12)
            let verses = (1...n).map { i in BibleVerse(chapter: 1, number: i, text: (0..<(1 + rng.next(260))).map { _ in ["a", "bb", "ccc", "dddd", "faith", "hope"][rng.next(6)] }.joined(separator: " ")) }
            let cap = 60 + rng.next(900), per = 1 + rng.next(6), limit = 100 + rng.next(900)
            let p = ScriptureService.build(ref: ref("Psalm 1:1"), verses: verses, abbreviation: "X", versesPerSlide: per, maxChars: cap, fits: { $0.count <= limit })
            assertWholeVerseSlides(p, verses, "round \(round) n=\(n) cap=\(cap) per=\(per) limit=\(limit)")
        }
    }

    func testCrossChapterPassagesUseChapterVerseMarkers() {
        let v = [BibleVerse(chapter: 3, number: 36, text: "He that believeth on the Son hath everlasting life."), BibleVerse(chapter: 4, number: 1, text: "When therefore the Lord knew how the Pharisees had heard.")]
        let p = ScriptureService.build(ref: ref("John 3:36-4:1"), verses: v, abbreviation: "KJV", versesPerSlide: 1, maxChars: 260)
        XCTAssertEqual(p.orderedSlides.count, 2)
        XCTAssertTrue(p.orderedSlides[1].slide.text.hasPrefix("4:1 "), p.orderedSlides[1].slide.text)
    }

    // MARK: very long verses still fit on screen

    private func opaqueRows(_ image: CIImage) -> (first: Int, last: Int)? {
        let rep = NSBitmapImageRep(ciImage: image)
        var first = Int.max, last = -1
        for y in 0..<rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                var px = [Int](repeating: 0, count: 4); rep.getPixel(&px, atX: x, y: y)
                if px[3] > 20 { first = min(first, y); last = max(last, y); break }
            }
        }
        return last < 0 ? nil : (first, last)
    }

    func testVeryLongVerseShrinksToFitFullSlideAndLowerThird() throws {
        let store = LibraryStore(folder: tempFolder())
        let p = ScriptureService.build(ref: ref("Esther 8:9"), verses: [esther89], abbreviation: "KJV", versesPerSlide: 1, maxChars: 260)
        XCTAssertEqual(p.orderedSlides.count, 1, "one verse stays on one slide even though it's ~600 characters")
        let slide = p.orderedSlides[0].slide
        let full = store.resolvedTheme(for: p)
        let img = try XCTUnwrap(Snapshot.render(SlideCanvas(text: slide.text, label: slide.label, theme: full, mode: .fullSlide), size: designSize, opaque: false))
        let rows = try XCTUnwrap(opaqueRows(img))
        XCTAssertGreaterThan(rows.first, 20, "text must not touch the top edge")
        XCTAssertLessThan(rows.last, Int(designSize.height) - 20, "text must not run off the bottom")

        let lt = try XCTUnwrap(store.data.themes.first { $0.name == "Bible Lower Third" })
        let ltImg = try XCTUnwrap(Snapshot.render(SlideCanvas(text: slide.text, label: slide.label, theme: lt, mode: .lowerThird), size: designSize, opaque: false))
        let ltRows = try XCTUnwrap(opaqueRows(ltImg))
        XCTAssertGreaterThan(ltRows.first, Int(designSize.height * 0.5), "the lower third must stay in the lower part of the picture (top at \(ltRows.first))")
        XCTAssertLessThan(ltRows.last, Int(designSize.height) - 20)
    }
}
