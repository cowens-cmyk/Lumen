import Foundation
import Security

struct BibleVerse: Hashable, Codable {
    var chapter: Int
    var number: Int
    var text: String
}

struct BibleTranslation: Hashable, Identifiable, Codable {
    var id: String
    var abbreviation: String
    var name: String
    var language: String = "English"
}

enum BibleError: LocalizedError {
    case missingKey(String), notFound, http(Int), parse
    var errorDescription: String? {
        switch self {
        case .missingKey(let s): "Add your \(s) API key in Settings → Bible."
        case .notFound: "That passage wasn't found in this translation."
        case .http(let c): "The Bible service returned HTTP \(c)."
        case .parse: "Couldn't read the passage returned by the Bible service."
        }
    }
}

protocol BibleProvider {
    func translations() async throws -> [BibleTranslation]
    func passage(_ ref: BibleReference, translation: String) async throws -> [BibleVerse]
}

// MARK: - Keychain

enum Keychain {
    private static let service = "org.hopejc.Lumen"

    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Pulls "[16] For God so loved..." style text into verses.
func parseBracketedVerses(_ text: String, chapter: Int) -> [BibleVerse] {
    let regex = try! NSRegularExpression(pattern: #"\[(\d+)(?::(\d+))?\]"#)
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var verses: [BibleVerse] = []
    var ch = chapter
    for (i, m) in matches.enumerated() {
        var num = Int(ns.substring(with: m.range(at: 1))) ?? 0
        if m.range(at: 2).location != NSNotFound {
            ch = num
            num = Int(ns.substring(with: m.range(at: 2))) ?? 0
        } else if let last = verses.last, num < last.number {
            ch += 1   // chapter rolled over in a cross-chapter passage
        }
        let start = m.range.location + m.range.length
        let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
        let body = ns.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { verses.append(BibleVerse(chapter: ch, number: num, text: body)) }
    }
    return verses
}

private func getJSON(_ req: URLRequest) async throws -> Any {
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
        throw h.statusCode == 404 ? BibleError.notFound : BibleError.http(h.statusCode)
    }
    return try JSONSerialization.jsonObject(with: data)
}

// MARK: - bible-api.com (public domain translations, no key)

struct BibleAPIComProvider: BibleProvider {
    func translations() async throws -> [BibleTranslation] {
        [
            BibleTranslation(id: "kjv", abbreviation: "KJV", name: "King James Version"),
            BibleTranslation(id: "web", abbreviation: "WEB", name: "World English Bible"),
            BibleTranslation(id: "asv", abbreviation: "ASV", name: "American Standard Version (1901)"),
            BibleTranslation(id: "bbe", abbreviation: "BBE", name: "Bible in Basic English"),
            BibleTranslation(id: "ylt", abbreviation: "YLT", name: "Young's Literal Translation"),
            BibleTranslation(id: "darby", abbreviation: "DARBY", name: "Darby Bible"),
            BibleTranslation(id: "oeb-us", abbreviation: "OEB", name: "Open English Bible (US)"),
            BibleTranslation(id: "webbe", abbreviation: "WEBBE", name: "World English Bible, British Edition"),
            BibleTranslation(id: "almeida", abbreviation: "ALMEIDA", name: "João Ferreira de Almeida", language: "Portuguese"),
            BibleTranslation(id: "rvr1909", abbreviation: "RVR1909", name: "Reina-Valera 1909", language: "Spanish"),
        ]
    }

    func passage(_ ref: BibleReference, translation: String) async throws -> [BibleVerse] {
        var c = URLComponents(string: "https://bible-api.com/")!
        c.percentEncodedPath = "/" + (ref.display.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
        c.queryItems = [URLQueryItem(name: "translation", value: translation)]
        let json = try await getJSON(URLRequest(url: c.url!)) as? [String: Any]
        guard let verses = json?["verses"] as? [[String: Any]], !verses.isEmpty else { throw BibleError.notFound }
        return verses.compactMap { v in
            guard let n = v["verse"] as? Int, let t = v["text"] as? String else { return nil }
            return BibleVerse(chapter: v["chapter"] as? Int ?? ref.chapter, number: n,
                              text: t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - API.Bible (American Bible Society) — thousands of translations with a free key

struct APIBibleProvider: BibleProvider {
    var apiKey: String

    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw BibleError.missingKey("API.Bible") }
        var c = URLComponents(string: "https://api.scripture.api.bible/v1/\(path)")!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.setValue(apiKey, forHTTPHeaderField: "api-key")
        return r
    }

    func translations() async throws -> [BibleTranslation] {
        let json = try await getJSON(try request("bibles")) as? [String: Any]
        let list = json?["data"] as? [[String: Any]] ?? []
        return list.compactMap { b in
            guard let id = b["id"] as? String else { return nil }
            let lang = (b["language"] as? [String: Any])?["name"] as? String ?? ""
            return BibleTranslation(id: id, abbreviation: (b["abbreviationLocal"] as? String) ?? (b["abbreviation"] as? String) ?? id,
                                    name: (b["nameLocal"] as? String) ?? (b["name"] as? String) ?? id, language: lang)
        }.sorted { ($0.language, $0.abbreviation) < ($1.language, $1.abbreviation) }
    }

    func passage(_ ref: BibleReference, translation: String) async throws -> [BibleVerse] {
        let r = try request("bibles/\(translation)/passages/\(ref.usfmPassageID)", query: [
            URLQueryItem(name: "content-type", value: "text"),
            URLQueryItem(name: "include-notes", value: "false"),
            URLQueryItem(name: "include-titles", value: "false"),
            URLQueryItem(name: "include-chapter-numbers", value: "false"),
            URLQueryItem(name: "include-verse-numbers", value: "true"),
            URLQueryItem(name: "include-verse-spans", value: "false"),
        ])
        let json = try await getJSON(r) as? [String: Any]
        guard let content = (json?["data"] as? [String: Any])?["content"] as? String else { throw BibleError.parse }
        let verses = parseBracketedVerses(content, chapter: ref.chapter)
        if verses.isEmpty { throw BibleError.notFound }
        return verses
    }
}

// MARK: - ESV API (Crossway)

struct ESVProvider: BibleProvider {
    var apiKey: String

    func translations() async throws -> [BibleTranslation] {
        [BibleTranslation(id: "esv", abbreviation: "ESV", name: "English Standard Version")]
    }

    func passage(_ ref: BibleReference, translation: String) async throws -> [BibleVerse] {
        guard !apiKey.isEmpty else { throw BibleError.missingKey("ESV") }
        var c = URLComponents(string: "https://api.esv.org/v3/passage/text/")!
        c.queryItems = [
            URLQueryItem(name: "q", value: ref.display),
            URLQueryItem(name: "include-passage-references", value: "false"),
            URLQueryItem(name: "include-verse-numbers", value: "true"),
            URLQueryItem(name: "include-first-verse-numbers", value: "true"),
            URLQueryItem(name: "include-footnotes", value: "false"),
            URLQueryItem(name: "include-headings", value: "false"),
            URLQueryItem(name: "include-short-copyright", value: "false"),
            URLQueryItem(name: "indent-paragraphs", value: "0"),
            URLQueryItem(name: "indent-poetry", value: "false"),
        ]
        var r = URLRequest(url: c.url!)
        r.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let json = try await getJSON(r) as? [String: Any]
        guard let text = (json?["passages"] as? [String])?.joined(separator: " ") else { throw BibleError.parse }
        let verses = parseBracketedVerses(text, chapter: ref.chapter)
        if verses.isEmpty { throw BibleError.notFound }
        return verses
    }
}

// MARK: - Local imported Bibles (Zefania / OSIS XML) — use any translation your church licenses

struct LocalBible: Codable {
    var translation: BibleTranslation
    /// book number → chapter → verse → text
    var books: [Int: [Int: [Int: String]]]
}

final class LocalBibleProvider: BibleProvider {
    let folder: URL
    private var cache: [String: LocalBible] = [:]

    init(folder: URL) { self.folder = folder }

    func translations() async throws -> [BibleTranslation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { load($0.deletingPathExtension().lastPathComponent)?.translation }
    }

    private func load(_ id: String) -> LocalBible? {
        if let c = cache[id] { return c }
        let url = folder.appendingPathComponent("\(id).json")
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(LocalBible.self, from: d) else { return nil }
        cache[id] = b
        return b
    }

    func passage(_ ref: BibleReference, translation: String) async throws -> [BibleVerse] {
        guard let bible = load(translation), let book = bible.books[ref.bookNumber] else { throw BibleError.notFound }
        var out: [BibleVerse] = []
        let endCh = ref.endChapter ?? ref.chapter
        for ch in ref.chapter...max(ref.chapter, endCh) {
            guard let verses = book[ch] else { continue }
            for n in verses.keys.sorted() {
                if ch == ref.chapter, let s = ref.verseStart, n < s { continue }
                if ch == endCh, let s = ref.verseStart {
                    let e = ref.verseEnd ?? (ref.endChapter == nil ? s : Int.max)
                    if n > e { continue }
                }
                out.append(BibleVerse(chapter: ch, number: n, text: verses[n]!))
            }
        }
        if out.isEmpty { throw BibleError.notFound }
        return out
    }

    /// Imports a Zefania or OSIS XML Bible and returns its translation record.
    @discardableResult
    func importXML(at url: URL, abbreviation: String) throws -> BibleTranslation {
        let data = try Data(contentsOf: url)
        let d = BibleXMLDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse(), !d.books.isEmpty else { throw BibleError.parse }
        let abbr = abbreviation.isEmpty ? url.deletingPathExtension().lastPathComponent : abbreviation
        let id = "local-" + abbr.lowercased().filter { $0.isLetter || $0.isNumber }
        let t = BibleTranslation(id: id, abbreviation: abbr.uppercased(), name: d.title.isEmpty ? abbr : d.title)
        let bible = LocalBible(translation: t, books: d.books)
        try JSONEncoder().encode(bible).write(to: folder.appendingPathComponent("\(id).json"))
        cache[id] = bible
        return t
    }
}

private final class BibleXMLDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var books: [Int: [Int: [Int: String]]] = [:]
    private var book = 0, chapter = 0, verse = 0
    private var inVerse = false
    private var buffer = ""
    private var inTitle = false
    private let osisBooks: [String: Int] = {
        let codes = ["Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth", "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr",
                     "2Chr", "Ezra", "Neh", "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer", "Lam", "Ezek", "Dan",
                     "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
                     "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil", "Col", "1Thess",
                     "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John",
                     "Jude", "Rev"]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0 + 1) })
    }()

    private func setOSIS(_ id: String) -> Bool {
        let parts = id.split(separator: ".")
        guard parts.count == 3, let b = osisBooks[String(parts[0])], let c = Int(parts[1]), let v = Int(parts[2]) else { return false }
        book = b; chapter = c; verse = v
        return true
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch name.uppercased() {
        case "XMLBIBLE": title = a["biblename"] ?? title
        case "BIBLEBOOK": book = Int(a["bnumber"] ?? "") ?? book
        case "CHAPTER" where a["cnumber"] != nil: chapter = Int(a["cnumber"]!) ?? chapter
        case "VERS": verse = Int(a["vnumber"] ?? "") ?? 0; inVerse = true; buffer = ""
        case "TITLE": inTitle = title.isEmpty
        case "VERSE":
            if let sid = a["sID"] ?? a["osisID"], setOSIS(sid.components(separatedBy: " ").first ?? sid) {
                inVerse = true; buffer = ""
            }
            if a["eID"] != nil { commit() }
        case "NOTE": inVerse = false   // skip footnotes
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inTitle { title += s }
        if inVerse { buffer += s }
    }

    private func commit() {
        guard inVerse, book > 0 else { return }
        let text = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { books[book, default: [:]][chapter, default: [:]][verse] = text }
        inVerse = false
        buffer = ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name.uppercased() {
        case "VERS": commit()
        case "VERSE": commit()
        case "TITLE": inTitle = false
        case "NOTE": if book > 0 && verse > 0 { inVerse = true }
        default: break
        }
    }
}
