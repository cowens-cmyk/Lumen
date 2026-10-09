import XCTest
@testable import Lumen

final class LyricParserTests: XCTestCase {
    let song = """
    Verse 1
    Amazing grace how sweet the sound
    That saved a wretch like me
    I once was lost but now am found
    Was blind but now I see

    Chorus
    My chains are gone
    I've been set free

    [Bridge]
    G   D/F#   Em   C
    The earth shall soon dissolve like snow

    CCLI Song # 4768151
    """

    func testSectionsAndChordStripping() {
        let s = LyricParser.sections(from: song)
        XCTAssertEqual(s.map(\.name), ["Verse 1", "Chorus", "Bridge"])
        XCTAssertEqual(s[2].lines, ["The earth shall soon dissolve like snow"])
    }

    func testSlidesSplitByMaxLines() {
        let p = LyricParser.presentation(name: "Amazing Grace", text: song, maxLines: 2)
        XCTAssertEqual(p.groups[0].slides.count, 2)
        XCTAssertEqual(p.groups[0].slides[1].text, "I once was lost but now am found\nWas blind but now I see")
    }

    func testArrangementFromPCOSequence() {
        let p = LyricParser.presentation(name: "x", text: song, maxLines: 2, sequence: ["V1", "Chorus", "Bridge", "C"])
        let names = p.arrangement.compactMap { id in p.groups.first { $0.id == id }?.name }
        XCTAssertEqual(names, ["Verse 1", "Chorus", "Bridge", "Chorus"])
        XCTAssertEqual(p.orderedSlides.count, 2 + 1 + 1 + 1)
    }

    func testReapplyKeepsGroupIDs() {
        var p = LyricParser.presentation(name: "x", text: song, maxLines: 2)
        let chorusID = p.groups[1].id
        LyricParser.apply(text: song.replacingOccurrences(of: "gone", with: "GONE"), to: &p, maxLines: 2)
        XCTAssertEqual(p.groups[1].id, chorusID)
        XCTAssertTrue(p.groups[1].slides[0].text.contains("GONE"))
    }

    func testHeadings() {
        XCTAssertEqual(LyricParser.heading("PRE-CHORUS 2:"), "Pre-Chorus 2")
        XCTAssertEqual(LyricParser.heading("[Tag]"), "Tag")
        XCTAssertNil(LyricParser.heading("Verses of the heart"))
        XCTAssertEqual(LyricParser.heading("Chorus (x2)"), "Chorus")
    }

    func testUSR() {
        let usr = "[S A4768151]\nTitle=Amazing Grace\nAuthor=John Newton\nFields=Verse 1/tChorus\nWords=Line a/nLine b/tLine c/nLine d\n"
        let r = LyricParser.parseUSR(usr)
        XCTAssertEqual(r.title, "Amazing Grace")
        XCTAssertEqual(r.ccli, "4768151")
        XCTAssertEqual(LyricParser.sections(from: r.lyrics).map(\.name), ["Verse 1", "Chorus"])
    }
}

final class ReferenceTests: XCTestCase {
    func testTyped() {
        XCTAssertEqual(ReferenceParser.parse("jn 3:16")?.display, "John 3:16")
        XCTAssertEqual(ReferenceParser.parse("1 Cor 13:4-7")?.display, "1 Corinthians 13:4-7")
        XCTAssertEqual(ReferenceParser.parse("Psalm 23")?.display, "Psalms 23")
        XCTAssertEqual(ReferenceParser.parse("Gen 32")?.display, "Genesis 32")
        XCTAssertEqual(ReferenceParser.parse("john 3 16")?.display, "John 3:16")
        XCTAssertEqual(ReferenceParser.parse("John 3:16-4:2")?.display, "John 3:16-4:2")
        XCTAssertNil(ReferenceParser.parse("Genesis 51"), "Genesis has 50 chapters")
    }

    func testUSFM() {
        XCTAssertEqual(ReferenceParser.parse("John 3:16-18")?.usfmPassageID, "JHN.3.16-JHN.3.18")
    }

    func testSpokenNormalization() {
        XCTAssertEqual(SpokenNormalizer.normalize("turn to Genesis chapter thirty two"), "turn to genesis 32")
        XCTAssertEqual(SpokenNormalizer.normalize("first Corinthians thirteen verse four through seven"), "1 corinthians 13:4-7")
        XCTAssertEqual(SpokenNormalizer.normalize("psalm one hundred nineteen"), "psalms 119")
        XCTAssertEqual(SpokenNormalizer.normalize("John three sixteen"), "john 3:16")
    }

    func testDetector() {
        var d = ScriptureDetector()
        let found = d.scan("this morning I want you to turn with me to Genesis chapter thirty two")
        XCTAssertEqual(found.first?.reference.display, "Genesis 32")
        XCTAssertTrue(d.scan("Genesis chapter thirty two").isEmpty, "deduplicated")
        var d2 = ScriptureDetector()
        XCTAssertTrue(d2.scan("I want to mark 5 things today").isEmpty, "ambiguous 'mark' without cue")
        XCTAssertEqual(d2.scan("Romans eight twenty eight says").first?.reference.display, "Romans 8:28")
    }

    func testScriptureBuild() {
        let ref = ReferenceParser.parse("John 3:16-17")!
        let p = ScriptureService.build(ref: ref, verses: [
            BibleVerse(chapter: 3, number: 16, text: "For God so loved the world"),
            BibleVerse(chapter: 3, number: 17, text: "For God sent not his Son"),
        ], abbreviation: "KJV", versesPerSlide: 1, maxChars: 300)
        XCTAssertEqual(p.kind, .scripture)
        XCTAssertEqual(p.orderedSlides.count, 2)
        XCTAssertEqual(p.orderedSlides[0].slide.label, "John 3:16 KJV")
        XCTAssertEqual(p.name, "John 3:16-17 KJV")
    }

    func testBracketedVerses() {
        let v = parseBracketedVerses("[16] For God so loved [17] For God sent", chapter: 3)
        XCTAssertEqual(v.map(\.number), [16, 17])
        XCTAssertEqual(v[0].text, "For God so loved")
    }
}

final class LyricFollowerTests: XCTestCase {
    let slides = [
        "Amazing grace how sweet the sound\nThat saved a wretch like me",
        "I once was lost but now am found\nWas blind but now I see",
        "My chains are gone\nI've been set free",
        "My God my Savior has ransomed me",
        "Amazing grace how sweet the sound\nThat saved a wretch like me",
    ]

    func testAdvancesWhenNextSlideIsSung() {
        var f = LyricFollower(slides: slides)
        f.advanceAtEndOfSlide = false
        let t0 = Date()
        _ = f.update(heardText: "amazing grace how sweet the sound", current: 0, now: t0)
        var d = f.update(heardText: "i once was lost but now am", current: 0, now: t0.addingTimeInterval(1))
        d = f.update(heardText: "i once was lost but now am found", current: 0, now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(d.kind, .advance(to: 1))
    }

    func testEarlyAdvanceAtEndOfSlide() {
        var f = LyricFollower(slides: slides)
        let d = f.update(heardText: "the sound that saved a wretch like me", current: 0)
        XCTAssertEqual(d.kind, .advance(to: 1))
    }

    func testRepeatedChorusPrefersForwardInstance() {
        var f = LyricFollower(slides: slides)
        f.advanceAtEndOfSlide = false
        let t0 = Date()
        _ = f.update(heardText: "amazing grace how sweet the sound", current: 3, now: t0)
        let d = f.update(heardText: "amazing grace how sweet the sound", current: 3, now: t0.addingTimeInterval(1))
        XCTAssertEqual(d.kind, .advance(to: 4), "should pick slide 4 not jump back to 0")
    }

    func testOffScriptHolds() {
        var f = LyricFollower(slides: slides)
        let t0 = Date()
        _ = f.update(heardText: "my chains are gone", current: 2, now: t0)
        let d = f.update(heardText: "come on church lift your hands tonight", current: 2, now: t0.addingTimeInterval(10))
        XCTAssertEqual(d.kind, .offScript)
    }

    func testFuzzyWords() {
        XCTAssertTrue(LyricFollower.similar("ransomed", "ransom"))
        XCTAssertTrue(LyricFollower.similar("savior", "saviour"))
        XCTAssertFalse(LyricFollower.similar("gone", "grace"))
    }
}

final class SchedulerTests: XCTestCase {
    @MainActor func testCalendarNotes() {
        let store = LibraryStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let actions = Scheduler.actions(fromNotes: "Setup\nlumen: macro Walk In\nlumen: slide Welcome 1\nlumen: clear all", store: store)
        XCTAssertEqual(actions.count, 3)
        if case .triggerMacro = actions[0] {} else { XCTFail() }
        if case .triggerPresentation(_, let slide) = actions[1] { XCTAssertEqual(slide, 0) } else { XCTFail() }
    }

    func testTimerFormat() {
        XCTAssertEqual(TimerRuntime.format(65), "1:05")
        XCTAssertEqual(TimerRuntime.format(-5), "-0:05")
        XCTAssertEqual(TimerRuntime.format(3725), "1:02:05")
    }
}

/// Auto-updates install new versions over old libraries. Any change to the saved format must keep this passing:
/// add new fields as Optional (or with custom decoding) so a library saved by an older Lumen still opens.
final class LibraryCompatibilityTests: XCTestCase {
    func testLibrarySavedByOlderVersionStillDecodes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "library-0.2.0", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let lib = try JSONDecoder.lumen.decode(LibraryData.self, from: data)
        XCTAssertFalse(lib.themes.isEmpty)
        XCTAssertEqual(lib.presentations.first?.key, "G")
        XCTAssertEqual(lib.presentations.first?.groups.first?.slides.first?.chords?.first?.chord, "G")
    }

    @MainActor func testVersionChangeBacksUpLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"old\":true}".utf8).write(to: dir.appendingPathComponent("library.json"))
        _ = LibraryStore(folder: dir)   // unreadable file is preserved, and the version change is backed up
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("library-unknown-before-") })
    }
}
