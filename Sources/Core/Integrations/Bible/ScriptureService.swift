import AppKit
import Foundation
import Observation

// MARK: - The church's Bible versions

/// One of the Bibles the church wants, and how to recognise it in each source's catalogue.
struct CuratedVersion: Identifiable, Hashable {
    let key: String
    let name: String
    let abbreviation: String
    /// Lower-case letters and digits only. A source's name must contain every one of these…
    let nameParts: [String]
    /// …and none of these (e.g. "new" keeps the New King James out of the King James).
    let excluded: [String]
    /// Abbreviations that identify it on their own.
    let abbreviations: Set<String>
    /// The NASB comes in two editions that must not be confused.
    let year: String?
    var id: String { key }
}

enum BibleSource: Hashable {
    case publicDomain(String)   // bible-api.com id
    case esv                    // Crossway's API
    case nlt                    // Tyndale's API
    case apiBible(String)       // API.Bible bible id
    case local(String)          // an imported Zefania/OSIS file

    var label: String {
        switch self {
        case .publicDomain: "public domain"
        case .esv: "ESV API"
        case .nlt: "NLT API"
        case .apiBible: "API.Bible"
        case .local: "imported file"
        }
    }
}

struct VersionStatus: Identifiable {
    let version: CuratedVersion
    let source: BibleSource?
    let detail: String
    var id: String { version.key }
    var isReady: Bool { source != nil }
}

enum BibleCatalog {
    /// In the order they appear in ProPresenter.
    static let curated: [CuratedVersion] = [
        CuratedVersion(key: "csb", name: "Christian Standard Bible", abbreviation: "CSB", nameParts: ["christianstandardbible"],
                       excluded: ["holman"], abbreviations: ["csb"], year: nil),
        CuratedVersion(key: "esv", name: "English Standard Version", abbreviation: "ESV", nameParts: ["englishstandardversion"],
                       excluded: ["anglicised", "uk"], abbreviations: ["esv"], year: nil),
        CuratedVersion(key: "kjv", name: "King James Version", abbreviation: "KJV", nameParts: ["kingjamesversion"],
                       excluded: ["new", "modern", "american"], abbreviations: ["kjv"], year: nil),
        CuratedVersion(key: "nasb1995", name: "New American Standard Bible 1995", abbreviation: "NASB 1995", nameParts: ["newamericanstandardbible"],
                       excluded: [], abbreviations: ["nasb95", "nasb1995"], year: "1995"),
        CuratedVersion(key: "nasb2020", name: "New American Standard Bible 2020", abbreviation: "NASB 2020", nameParts: ["newamericanstandardbible"],
                       excluded: [], abbreviations: ["nasb20", "nasb2020"], year: "2020"),
        CuratedVersion(key: "niv", name: "New International Version", abbreviation: "NIV", nameParts: ["newinternationalversion"],
                       excluded: ["reader", "anglicised", "uk", "1984", "children"], abbreviations: ["niv"], year: nil),
        CuratedVersion(key: "nkjv", name: "New King James Version", abbreviation: "NKJV", nameParts: ["newkingjamesversion"],
                       excluded: [], abbreviations: ["nkjv"], year: nil),
        CuratedVersion(key: "nlt", name: "New Living Translation", abbreviation: "NLT", nameParts: ["newlivingtranslation"],
                       excluded: ["children"], abbreviations: ["nlt"], year: nil),
        CuratedVersion(key: "msg", name: "The Message", abbreviation: "MSG", nameParts: ["themessage"],
                       excluded: [], abbreviations: ["msg"], year: nil),
    ]

    static func curated(key: String) -> CuratedVersion? { curated.first { $0.key == key } }

    /// Letters and digits only, lower case: "New American Standard Bible, 1995" → "newamericanstandardbible1995".
    static func normalize(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Finds `version` in a source's catalogue (English only), preferring an exact abbreviation match.
    static func match(_ v: CuratedVersion, in list: [BibleTranslation]) -> BibleTranslation? {
        func isEnglish(_ t: BibleTranslation) -> Bool { t.language.isEmpty || t.language.lowercased().hasPrefix("eng") }
        var best: (score: Int, t: BibleTranslation)?
        for t in list where isEnglish(t) {
            let n = normalize(t.name), a = normalize(t.abbreviation)
            let banned = v.excluded.contains { n.contains($0) }
            let nameHit = v.nameParts.allSatisfy { n.contains($0) } && !banned
            let abbrHit = !banned && (v.abbreviations.contains(a) || (v.year == nil && a == normalize(v.abbreviation)))
            guard nameHit || abbrHit else { continue }
            if let y = v.year, !editionMatches(y, name: n, abbr: a) { continue }
            let score = (abbrHit ? 2 : 0) + (nameHit ? 1 : 0)
            if best == nil || score > best!.score { best = (score, t) }
        }
        return best?.t
    }

    /// NASB 1995 vs 2020: the source must say which (in the name or the abbreviation); a bare "NASB" is the 1995 text.
    static func editionMatches(_ year: String, name n: String, abbr a: String) -> Bool {
        let other = year == "1995" ? "2020" : "1995"
        func says(_ y: String) -> Bool { n.contains(y) || a.contains(y) || (a.hasPrefix("nasb") && a.hasSuffix(String(y.suffix(2)))) }
        if says(year) { return true }
        if says(other) { return false }
        return year == "1995"
    }
}

// MARK: - Service

/// Fetches passages from whichever source holds the chosen Bible and turns them into themed scripture presentations.
@MainActor
@Observable
final class ScriptureService {
    let store: LibraryStore
    @ObservationIgnored private var cache: [String: [BibleVerse]] = [:]

    /// What the church's API.Bible key can read (nil until checked or if there's no key).
    private(set) var apiBibleList: [BibleTranslation]?
    private(set) var apiBibleProblem: String?
    private(set) var localList: [BibleTranslation] = []
    private(set) var checking = false

    /// Where API keys come from (the Keychain); tests substitute their own.
    @ObservationIgnored var keys: (String) -> String = { Keychain.get($0) }
    @ObservationIgnored var providerOverride: ((BibleSource) -> BibleProvider)?

    init(store: LibraryStore) { self.store = store }

    @ObservationIgnored lazy var local = LocalBibleProvider(folder: store.biblesFolder)

    // MARK: Catalogue

    /// Lets tests set what the sources offer without any network or imported files.
    func setCatalogForTesting(apiBible: [BibleTranslation]?, local: [BibleTranslation] = []) {
        apiBibleList = apiBible
        localList = local
    }

    /// Re-reads imported files and, if there's an API.Bible key, asks it which Bibles it can supply.
    func refreshCatalog() async {
        checking = true
        defer { checking = false }
        localList = (try? await local.translations()) ?? []
        apiBibleProblem = nil
        if keys("apibible-key").isEmpty { apiBibleList = nil; return }
        do { apiBibleList = try await APIBibleProvider(apiKey: keys("apibible-key")).translations() }
        catch { apiBibleList = nil; apiBibleProblem = error.localizedDescription }
    }

    /// Where `v` can come from right now. Order: a file you imported (works offline, and it's the licence you hold), then
    /// the publisher's own free API, then API.Bible.
    func source(for v: CuratedVersion) -> BibleSource? {
        if let t = BibleCatalog.match(v, in: localList) { return .local(t.id) }
        switch v.key {
        case "kjv": return .publicDomain("kjv")
        case "esv": if !keys("esv-key").isEmpty { return .esv }
        case "nlt": if !keys("nlt-key").isEmpty { return .nlt }
        default: break
        }
        if let list = apiBibleList, let t = BibleCatalog.match(v, in: list) { return .apiBible(t.id) }
        return nil
    }

    func status(for v: CuratedVersion) -> VersionStatus {
        if let s = source(for: v) { return VersionStatus(version: v, source: s, detail: "Ready — \(s.label)") }
        let haveAPIBible = !keys("apibible-key").isEmpty
        let detail: String
        switch v.key {
        case "esv": detail = "Add your free ESV API key (api.esv.org), or import a licensed file."
        case "nlt": detail = "Add your free NLT API key (api.nlt.to), or import a licensed file."
        default:
            if !haveAPIBible { detail = "Add an API.Bible key to see if it's included, or import a licensed file." }
            else if let list = apiBibleList { detail = "Not included in your API.Bible key (it offers \(list.count) versions). Request it in your API.Bible account, or import a licensed file." }
            else if let p = apiBibleProblem { detail = "Couldn't check API.Bible: \(p)" }
            else { detail = "Checking API.Bible…" }
        }
        return VersionStatus(version: v, source: nil, detail: detail)
    }

    var statuses: [VersionStatus] { BibleCatalog.curated.map(status(for:)) }

    // MARK: Selection

    /// "v:esv" for one of the nine, "p:<provider>:<id>" for anything else.
    var selection: String {
        get { store.data.settings.bibleSelection ?? "p:\(store.data.settings.bibleProvider.rawValue):\(store.data.settings.bibleTranslation)" }
        set { store.data.settings.bibleSelection = newValue }
    }

    var keepLineBreaks: Bool { store.data.settings.bibleKeepLineBreaks ?? false }

    struct Resolved { var source: BibleSource; var translationID: String; var abbreviation: String }

    func resolve(_ selection: String) throws -> Resolved {
        let parts = selection.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "v", let v = BibleCatalog.curated(key: parts[1]) {
            guard let s = source(for: v) else { throw BibleError.unavailable("\(v.name) isn't set up yet. \(status(for: v).detail)") }
            let id: String
            switch s {
            case .publicDomain(let i), .apiBible(let i), .local(let i): id = i
            case .esv: id = "esv"
            case .nlt: id = "nlt"
            }
            return Resolved(source: s, translationID: id, abbreviation: v.abbreviation)
        }
        if parts.count == 3, parts[0] == "p", let kind = BibleProviderKind(rawValue: parts[1]) {
            let source: BibleSource
            switch kind {
            case .bibleAPIcom: source = .publicDomain(parts[2])
            case .apiBible: source = .apiBible(parts[2])
            case .esv: source = .esv
            case .nlt: source = .nlt
            case .local: source = .local(parts[2])
            }
            return Resolved(source: source, translationID: parts[2], abbreviation: parts[2].uppercased())
        }
        throw BibleError.unavailable("Pick a Bible version first.")
    }

    func provider(for source: BibleSource) -> BibleProvider {
        if let providerOverride { return providerOverride(source) }
        switch source {
        case .publicDomain: return BibleAPIComProvider()
        case .esv: return ESVProvider(apiKey: keys("esv-key"))
        case .nlt: return NLTProvider(apiKey: keys("nlt-key"))
        case .apiBible: return APIBibleProvider(apiKey: keys("apibible-key"))
        case .local: return local
        }
    }

    /// Every other translation a source can supply, for the "More" part of the picker.
    func moreOptions() async -> [(tag: String, label: String)] {
        var out: [(String, String)] = []
        let curatedIDs = Set(BibleCatalog.curated.compactMap { source(for: $0) })
        if let pd = try? await BibleAPIComProvider().translations() {
            for t in pd where t.id != "kjv" { out.append(("p:bibleAPIcom:\(t.id)", "\(t.abbreviation) — \(t.name)")) }
        }
        for t in localList where !curatedIDs.contains(.local(t.id)) { out.append(("p:local:\(t.id)", "\(t.abbreviation) — \(t.name) (imported)")) }
        if let list = apiBibleList {
            for t in list where !curatedIDs.contains(.apiBible(t.id)) && (t.language.isEmpty || t.language.lowercased().hasPrefix("eng")) {
                out.append(("p:apiBible:\(t.id)", "\(t.abbreviation) — \(t.name)"))
            }
        }
        return out
    }

    // MARK: Passages

    func verses(_ ref: BibleReference, selection: String? = nil) async throws -> (verses: [BibleVerse], abbreviation: String) {
        let sel = selection ?? self.selection
        let r = try resolve(sel)
        let key = "\(sel)|\(r.source.label)|\(r.translationID)|\(ref.display)"
        if let c = cache[key] { return (c, r.abbreviation) }
        let v = try await provider(for: r.source).passage(ref, translation: r.translationID)
        cache[key] = v
        return (v, r.abbreviation)
    }

    /// Builds a scripture presentation that picks up the scripture theme (and the Bible lower third on the stream look).
    func presentation(for ref: BibleReference, selection: String? = nil) async throws -> Presentation {
        let (verses, abbr) = try await self.verses(ref, selection: selection)
        let s = store.data.settings
        let theme = store.resolvedTheme(for: Presentation(name: "", kind: .scripture))
        return Self.build(ref: ref, verses: verses, abbreviation: abbr,
                          versesPerSlide: s.bibleVersesPerSlide, maxChars: s.bibleMaxCharsPerSlide,
                          fits: Self.fitTest(theme: theme), keepLineBreaks: s.bibleKeepLineBreaks ?? false)
    }

    // MARK: Slides

    /// Builds the slides for a passage.
    ///
    /// - **A slide never starts in the middle of a verse.** Whole verses are packed onto a slide while they still fit (up to
    ///   `versesPerSlide`, `maxChars`, and the optional real-layout test `fits`); when the next verse wouldn't fit, that whole
    ///   verse starts the next slide. A single verse too long for any slide stays whole on a slide of its own (the theme's
    ///   shrink-to-fit makes it fit) rather than being cut.
    /// - **Line breaks are removed by default**, so scripture runs as straight text from top to bottom. `keepLineBreaks`
    ///   puts the translation's own breaks (poetry, paragraphs) back.
    nonisolated static func build(ref: BibleReference, verses rawVerses: [BibleVerse], abbreviation: String,
                                  versesPerSlide: Int, maxChars: Int, fits: ((String) -> Bool)? = nil,
                                  keepLineBreaks: Bool = false) -> Presentation {
        let verses = rawVerses.map { BibleVerse(chapter: $0.chapter, number: $0.number, text: BibleText.forSlide($0.text, keepLineBreaks: keepLineBreaks)) }
        var slides: [Slide] = []
        let crossChapter = Set(verses.map(\.chapter)).count > 1
        func label(_ vs: [BibleVerse]) -> String {
            guard let f = vs.first, let l = vs.last else { return "" }
            var s = "\(ref.book.name) \(f.chapter):\(f.number)"
            if l.chapter != f.chapter { s += "-\(l.chapter):\(l.number)" } else if l.number != f.number { s += "-\(l.number)" }
            return s + " \(abbreviation)"
        }
        func numbered(_ v: BibleVerse) -> String {
            (crossChapter ? "\(v.chapter):\(v.number)" : superscript(v.number)) + " " + v.text
        }
        func text(_ vs: [BibleVerse]) -> String { vs.map(numbered).joined(separator: " ") }

        var chunk: [BibleVerse] = []
        func flushChunk() {
            guard !chunk.isEmpty else { return }
            slides.append(Slide(text: text(chunk), label: label(chunk)))
            chunk = []
        }
        for v in verses {
            // The first verse on a slide is always accepted, however long. Later verses must fit alongside it.
            if !chunk.isEmpty {
                let combined = text(chunk + [v])
                let roomy = chunk.count < max(1, versesPerSlide) && combined.count <= maxChars && (fits?(combined) ?? true)
                if !roomy { flushChunk() }
            }
            chunk.append(v)
        }
        flushChunk()

        let title = label(verses)
        var p = Presentation(name: title, kind: .scripture)
        p.groups = [SlideGroup(name: ref.display, color: RGBA(hex: "#38BDF8"), slides: slides)]
        return p
    }

    /// A test that measures real text: does `text` fit on a slide in this theme at its normal size (no shrinking)?
    /// Uses the theme's font, size, margins, line spacing and reference label, so changing the theme changes where slides break.
    nonisolated static func fitTest(theme: Theme) -> (String) -> Bool {
        let width = max(200, designSize.width - 2 * theme.padding)
        var height = designSize.height - 2 * theme.padding
        if theme.showLabel { height -= theme.labelSize * 1.5 + 24 }
        height *= 0.92   // SwiftUI and AppKit lay text out almost, not exactly, the same: keep a margin
        let manager = NSFontManager.shared
        var font = NSFont(name: theme.fontName, size: theme.fontSize) ?? NSFont.systemFont(ofSize: theme.fontSize)
        if theme.bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = theme.lineSpacing
        para.alignment = .left
        return { text in
            let s = theme.uppercase ? text.uppercased() : text
            let rect = (s as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: [.font: font, .paragraphStyle: para])
            return rect.height <= height
        }
    }

    nonisolated static func superscript(_ n: Int) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        return String(String(n).compactMap { map[$0] })
    }
}
