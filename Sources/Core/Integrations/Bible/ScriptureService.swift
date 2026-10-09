import Foundation

/// Fetches passages from the configured provider and turns them into themed scripture presentations.
@MainActor
final class ScriptureService {
    let store: LibraryStore
    private var cache: [String: [BibleVerse]] = [:]

    init(store: LibraryStore) { self.store = store }

    lazy var local = LocalBibleProvider(folder: store.biblesFolder)

    func provider(_ kind: BibleProviderKind? = nil) -> BibleProvider {
        switch kind ?? store.data.settings.bibleProvider {
        case .bibleAPIcom: BibleAPIComProvider()
        case .apiBible: APIBibleProvider(apiKey: Keychain.get("apibible-key"))
        case .esv: ESVProvider(apiKey: Keychain.get("esv-key"))
        case .local: local
        }
    }

    func translations() async -> [BibleTranslation] {
        (try? await provider().translations()) ?? []
    }

    func verses(_ ref: BibleReference, translation: String? = nil) async throws -> [BibleVerse] {
        let t = translation ?? store.data.settings.bibleTranslation
        let key = "\(store.data.settings.bibleProvider.rawValue)|\(t)|\(ref.display)"
        if let c = cache[key] { return c }
        let v = try await provider().passage(ref, translation: t)
        cache[key] = v
        return v
    }

    func abbreviation(for translation: String) async -> String {
        if let t = await translations().first(where: { $0.id == translation }) { return t.abbreviation }
        return translation.uppercased()
    }

    /// Builds a scripture presentation that picks up the scripture theme (and Bible lower third on the stream look).
    func presentation(for ref: BibleReference, translation: String? = nil) async throws -> Presentation {
        let t = translation ?? store.data.settings.bibleTranslation
        let verses = try await verses(ref, translation: t)
        let abbr = await abbreviation(for: t)
        let s = store.data.settings
        return Self.build(ref: ref, verses: verses, abbreviation: abbr,
                          versesPerSlide: s.bibleVersesPerSlide, maxChars: s.bibleMaxCharsPerSlide)
    }

    nonisolated static func build(ref: BibleReference, verses: [BibleVerse], abbreviation: String,
                                  versesPerSlide: Int, maxChars: Int) -> Presentation {
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

        var chunk: [BibleVerse] = []
        func flushChunk() {
            guard !chunk.isEmpty else { return }
            slides.append(Slide(text: chunk.map(numbered).joined(separator: " "), label: label(chunk)))
            chunk = []
        }
        for v in verses {
            if v.text.count > maxChars {
                flushChunk()
                // Long verse: split across slides at sentence / word boundaries.
                let parts = splitText(v.text, maxChars: maxChars)
                for (i, part) in parts.enumerated() {
                    slides.append(Slide(text: (i == 0 ? superscript(v.number) + " " : "") + part, label: label([v])))
                }
                continue
            }
            let projected = (chunk + [v]).map(numbered).joined(separator: " ").count
            if chunk.count >= max(1, versesPerSlide) || projected > maxChars { flushChunk() }
            chunk.append(v)
        }
        flushChunk()

        let title = label(verses)
        var p = Presentation(name: title, kind: .scripture)
        p.groups = [SlideGroup(name: ref.display, color: RGBA(hex: "#38BDF8"), slides: slides)]
        return p
    }

    nonisolated static func superscript(_ n: Int) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        return String(String(n).compactMap { map[$0] })
    }

    nonisolated static func splitText(_ text: String, maxChars: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        // Break at the word limit, but prefer ending a slide at a sentence once it's reasonably full.
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > maxChars, !current.isEmpty {
                parts.append(current)
                current = String(word)
            } else {
                current = candidate
            }
            if let last = current.last, ".;:!?".contains(last), current.count > maxChars * 6 / 10 {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
