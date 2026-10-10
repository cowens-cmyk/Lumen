import XCTest
@testable import Lumen

private func bible(_ id: String, _ abbr: String, _ name: String, _ lang: String = "English") -> BibleTranslation {
    BibleTranslation(id: id, abbreviation: abbr, name: name, language: lang)
}

/// What an API.Bible account that includes most of the church's versions (and plenty of decoys) might list.
private let apiBibleLike: [BibleTranslation] = [
    bible("a1", "CSB", "Christian Standard Bible"), bible("a2", "HCSB", "Holman Christian Standard Bible"),
    bible("a3", "ESV", "English Standard Version"), bible("a4", "ESVUK", "English Standard Version Anglicised"),
    bible("a5", "KJV", "King James Version"), bible("a6", "NKJV", "New King James Version"),
    bible("a7", "NASB95", "New American Standard Bible, 1995"), bible("a8", "NASB20", "New American Standard Bible, 2020"),
    bible("a9", "NIV", "New International Version"), bible("a10", "NIVUK", "New International Version (Anglicised)"),
    bible("a11", "NIrV", "New International Reader's Version"), bible("a12", "NLT", "New Living Translation"),
    bible("a13", "MSG", "The Message"), bible("a14", "RVR60", "Reina-Valera 1960", "Spanish"), bible("a15", "LSG", "Louis Segond", "French"),
]

final class BibleCatalogTests: XCTestCase {
    func testEachOfTheNineIsFoundWithoutMixingUpLookAlikes() {
        let expected = ["csb": "a1", "esv": "a3", "kjv": "a5", "nasb1995": "a7", "nasb2020": "a8", "niv": "a9", "nkjv": "a6", "nlt": "a12", "msg": "a13"]
        for v in BibleCatalog.curated {
            XCTAssertEqual(BibleCatalog.match(v, in: apiBibleLike)?.id, expected[v.key], "\(v.name)")
        }
        XCTAssertEqual(BibleCatalog.curated.map(\.key), ["csb", "esv", "kjv", "nasb1995", "nasb2020", "niv", "nkjv", "nlt", "msg"], "same order as ProPresenter")
    }

    func testNASBEditionsAreNeverConfused() {
        let v95 = BibleCatalog.curated(key: "nasb1995")!, v20 = BibleCatalog.curated(key: "nasb2020")!
        let only2020 = [bible("x", "NASB20", "New American Standard Bible 2020")]
        XCTAssertNil(BibleCatalog.match(v95, in: only2020), "a 2020 text must never be offered as the 1995")
        XCTAssertEqual(BibleCatalog.match(v20, in: only2020)?.id, "x")
        let only95 = [bible("y", "NASB1995", "New American Standard Bible 1995")]
        XCTAssertNil(BibleCatalog.match(v20, in: only95))
        XCTAssertEqual(BibleCatalog.match(v95, in: only95)?.id, "y")
        // A plain "NASB" with no year is the 1995 text, and is not offered as 2020
        let bare = [bible("z", "NASB", "New American Standard Bible")]
        XCTAssertEqual(BibleCatalog.match(v95, in: bare)?.id, "z")
        XCTAssertNil(BibleCatalog.match(v20, in: bare))
    }

    func testOtherLanguagesAndMissingVersionsAreNotMatched() {
        let spanishOnly = [bible("s", "NVI", "Nueva Versión Internacional", "Spanish"), bible("r", "NIV", "New International Version", "Spanish")]
        XCTAssertNil(BibleCatalog.match(BibleCatalog.curated(key: "niv")!, in: spanishOnly))
        XCTAssertNil(BibleCatalog.match(BibleCatalog.curated(key: "msg")!, in: [bible("a", "KJV", "King James Version")]))
        XCTAssertNil(BibleCatalog.match(BibleCatalog.curated(key: "kjv")!, in: [bible("n", "NKJV", "New King James Version")]), "NKJV is not the KJV")
    }
}

@MainActor
final class BibleRoutingTests: XCTestCase {
    private var keys: [String: String] = [:]
    private var calls: [String] = []

    private func service(apiBible: [BibleTranslation]? = nil, local: [BibleTranslation] = []) -> ScriptureService {
        let svc = ScriptureService(store: LibraryStore(folder: tempFolder()))
        svc.keys = { [unowned self] in self.keys[$0] ?? "" }
        svc.setCatalogForTesting(apiBible: apiBible, local: local)
        svc.providerOverride = { [unowned self] source in
            struct Stub: BibleProvider {
                var source: BibleSource; var log: (String) -> Void
                func translations() async throws -> [BibleTranslation] { [] }
                func passage(_ ref: BibleReference, translation: String) async throws -> [BibleVerse] {
                    log("\(source.label)/\(translation)/\(ref.display)")
                    // a poetic verse, as sources return it: with its own line breaks
                    return [BibleVerse(chapter: ref.chapter, number: ref.verseStart ?? 1, text: "The Lord is my shepherd;\nI shall not want.\n\nHe makes me lie down")]
                }
            }
            return Stub(source: source, log: { self.calls.append($0) })
        }
        return svc
    }

    func testOnlyKJVWorksWithNoKeysAndTheOthersExplainWhatToDo() {
        let svc = service()
        let s = Dictionary(uniqueKeysWithValues: svc.statuses.map { ($0.version.key, $0) })
        XCTAssertTrue(s["kjv"]!.isReady)
        for k in ["csb", "esv", "nasb1995", "nasb2020", "niv", "nkjv", "nlt", "msg"] { XCTAssertFalse(s[k]!.isReady, k) }
        XCTAssertTrue(s["esv"]!.detail.contains("ESV API key"))
        XCTAssertTrue(s["nlt"]!.detail.contains("NLT API key"))
        XCTAssertTrue(s["niv"]!.detail.contains("API.Bible"))
    }

    func testKeysUnlockTheirOwnVersionsOnly() {
        keys = ["esv-key": "k"]
        var svc = service()
        XCTAssertEqual(svc.source(for: BibleCatalog.curated(key: "esv")!), .esv)
        XCTAssertNil(svc.source(for: BibleCatalog.curated(key: "nlt")!))
        keys = ["nlt-key": "k"]
        svc = service()
        XCTAssertEqual(svc.source(for: BibleCatalog.curated(key: "nlt")!), .nlt)
    }

    func testAPIBibleSuppliesWhateverTheKeyIncludes() {
        keys = ["apibible-key": "k"]
        let included = apiBibleLike.filter { ["NASB95", "NIV", "NKJV", "CSB"].contains($0.abbreviation) }
        let svc = service(apiBible: included)
        let ready = Set(svc.statuses.filter(\.isReady).map(\.version.key))
        XCTAssertEqual(ready, ["kjv", "nasb1995", "niv", "nkjv", "csb"])
        XCTAssertEqual(svc.source(for: BibleCatalog.curated(key: "niv")!), .apiBible("a9"))
        let msg = svc.status(for: BibleCatalog.curated(key: "msg")!)
        XCTAssertTrue(msg.detail.contains("Not included in your API.Bible key"), msg.detail)
    }

    func testImportedFileWinsAndWorksOffline() {
        keys = ["esv-key": "k", "apibible-key": "k"]
        let svc = service(apiBible: apiBibleLike, local: [bible("local-niv", "NIV", "New International Version")])
        XCTAssertEqual(svc.source(for: BibleCatalog.curated(key: "niv")!), .local("local-niv"), "your licensed file beats the network")
        XCTAssertEqual(svc.source(for: BibleCatalog.curated(key: "esv")!), .esv, "no ESV file: use the publisher's API before API.Bible")
    }

    func testFetchGoesToTheRightSourceWithTheRightID() async throws {
        keys = ["esv-key": "k", "nlt-key": "k", "apibible-key": "k"]
        let svc = service(apiBible: apiBibleLike)
        for (sel, expect) in [("v:esv", "ESV API/esv/Psalms 23:1"), ("v:nlt", "NLT API/nlt/Psalms 23:1"), ("v:niv", "API.Bible/a9/Psalms 23:1"),
                              ("v:nasb2020", "API.Bible/a8/Psalms 23:1"), ("v:kjv", "public domain/kjv/Psalms 23:1"), ("p:bibleAPIcom:web", "public domain/web/Psalms 23:1")] {
            calls = []
            _ = try await svc.verses(ReferenceParser.parse("Psalm 23:1")!, selection: sel)
            XCTAssertEqual(calls, [expect], sel)
        }
    }

    func testAnUnavailableVersionFailsWithAClearMessageNotAWrongBible() async {
        let svc = service()
        do { _ = try await svc.verses(ReferenceParser.parse("John 3:16")!, selection: "v:niv"); XCTFail("must not return text") }
        catch { XCTAssertTrue(error.localizedDescription.contains("New International Version isn't set up yet"), error.localizedDescription) }
        XCTAssertTrue(calls.isEmpty, "nothing was fetched from anywhere")
    }

    func testOlderSettingsStillSelectTheSameBible() {
        let svc = service()
        svc.store.data.settings.bibleSelection = nil
        svc.store.data.settings.bibleProvider = .bibleAPIcom
        svc.store.data.settings.bibleTranslation = "web"
        XCTAssertEqual(svc.selection, "p:bibleAPIcom:web")
        XCTAssertEqual(try svc.resolve(svc.selection).translationID, "web")
        svc.selection = "v:esv"
        XCTAssertEqual(svc.store.data.settings.bibleSelection, "v:esv")
    }

    // MARK: line breaks

    func testLineBreaksAreRemovedByDefaultAndCanBePutBack() async throws {
        let svc = service()
        var p = try await svc.presentation(for: ReferenceParser.parse("Psalm 23:1")!, selection: "v:kjv")
        XCTAssertFalse(p.orderedSlides[0].slide.text.contains("\n"), "straight text from top to bottom")
        XCTAssertTrue(p.orderedSlides[0].slide.text.contains("shepherd; I shall not want. He makes me lie down"), p.orderedSlides[0].slide.text)
        svc.store.data.settings.bibleKeepLineBreaks = true
        p = try await svc.presentation(for: ReferenceParser.parse("Psalm 23:1")!, selection: "v:kjv")
        XCTAssertEqual(p.orderedSlides[0].slide.text, "¹ The Lord is my shepherd;\nI shall not want.\nHe makes me lie down", "the translation's own breaks, blank lines dropped")
    }
}

final class LineBreakTextTests: XCTestCase {
    func testTidyAndForSlide() {
        let raw = "  For God so loved \t the world,\r\n\r\n   that he gave\u{00A0}his Son.  \n"
        XCTAssertEqual(BibleText.tidy(raw), "For God so loved the world,\nthat he gave his Son.")
        XCTAssertEqual(BibleText.forSlide(raw, keepLineBreaks: false), "For God so loved the world, that he gave his Son.")
        XCTAssertEqual(BibleText.forSlide(raw, keepLineBreaks: true), "For God so loved the world,\nthat he gave his Son.")
        XCTAssertEqual(BibleText.forSlide("", keepLineBreaks: false), "")
        XCTAssertEqual(BibleText.forSlide("\n\n  \n", keepLineBreaks: true), "")
    }

    func testVersesFromAPIBibleAndESVKeepTheirBreaksUntilSlideTime() {
        let v = parseBracketedVerses("[1] The Lord is my shepherd;\n    I shall not want.\n[2] He makes me lie down", chapter: 23)
        XCTAssertEqual(v.map(\.text), ["The Lord is my shepherd;\nI shall not want.", "He makes me lie down"])
    }

    func testBuildNeverLeavesALineBreakUnlessAsked() {
        let verses = [BibleVerse(chapter: 1, number: 1, text: "line one\nline two\n\nline three"), BibleVerse(chapter: 1, number: 2, text: "next\nverse")]
        let ref = ReferenceParser.parse("Genesis 1:1-2")!
        let plain = ScriptureService.build(ref: ref, verses: verses, abbreviation: "X", versesPerSlide: 5, maxChars: 500)
        XCTAssertFalse(plain.orderedSlides.contains { $0.slide.text.contains("\n") })
        XCTAssertEqual(plain.orderedSlides[0].slide.text, "¹ line one line two line three ² next verse")
        let kept = ScriptureService.build(ref: ref, verses: verses, abbreviation: "X", versesPerSlide: 5, maxChars: 500, keepLineBreaks: true)
        XCTAssertEqual(kept.orderedSlides[0].slide.text, "¹ line one\nline two\nline three ² next\nverse")
    }
}

final class NLTParsingTests: XCTestCase {
    /// Structure copied from the live API (words are placeholders): a footnote marker plus a note containing nested spans,
    /// red-letter words, a heading, and poetry lines.
    let html = """
    <!DOCTYPE html><html><body><div id="bibletext"><section><h2 class="bk_ch_vs_header">Sample 1:1, NLT</h2>
    <verse_export orig="sample_1_1" bk="sample" ch="1" vn="1">
    <h3 class="subhead">A Heading</h3>
    <p class="body"><span class="vn">1</span><span class="red">“Alpha beta gamma delta,<a class="a-tn">*</a><span class="tn"><span class="tn-ref">1:1</span> Or <em>epsilon zeta eta.</em></span> theta iota kappa.</span> </verse_export>
    <verse_export orig="sample_1_2" bk="sample" ch="1" vn="2">
    <p class="poet1"><span class="vn">2</span><span class="line">Lambda mu nu,</span></p><p class="poet2"><span class="line">xi omicron pi &amp; rho.</span></p></verse_export>
    <verse_export orig="sample_2_1" bk="sample" ch="2" vn="1"><p class="body"><span class="vn">1</span>Sigma tau&#8217;s upsilon.</p></verse_export>
    </section></div></body></html>
    """

    func testFootnotesHeadingsAndNumbersAreRemovedAndStructureKept() {
        let v = NLTProvider.parse(html: html, fallbackChapter: 1)
        XCTAssertEqual(v.map(\.number), [1, 2, 1])
        XCTAssertEqual(v.map(\.chapter), [1, 1, 2])
        XCTAssertEqual(v[0].text, "“Alpha beta gamma delta, theta iota kappa.", "no asterisk, no note text, no heading, no verse number")
        XCTAssertEqual(v[1].text, "Lambda mu nu,\nxi omicron pi & rho.", "poetry lines kept as lines (removed later unless 'keep line breaks')")
        XCTAssertEqual(v[2].text, "Sigma tau’s upsilon.", "entities decoded")
    }

    func testReferenceFormat() {
        XCTAssertEqual(NLTProvider.refString(ReferenceParser.parse("John 3:16-18")!), "John 3:16-18")
        XCTAssertEqual(NLTProvider.refString(ReferenceParser.parse("1 Cor 13:4")!), "1 Corinthians 13:4")
        XCTAssertEqual(NLTProvider.refString(ReferenceParser.parse("Psalm 23")!), "Psalms 23")
        XCTAssertEqual(NLTProvider.refString(ReferenceParser.parse("John 3:36-4:2")!), "John 3:36-4:2")
        XCTAssertEqual(NLTProvider.refString(ReferenceParser.parse("Jude 3")!), "Jude 1:3")
    }

    func testGarbageDoesNotCrash() {
        for junk in ["", "<verse_export>", "<verse_export vn=\"x\">hi</verse_export>", String(repeating: "<span class=\"tn\">", count: 5000), "<a class=\"a-tn\">*"] {
            _ = NLTProvider.parse(html: junk, fallbackChapter: 1)
        }
    }
}
