import Foundation

struct BibleReference: Hashable, Codable, Identifiable {
    var bookNumber: Int
    var chapter: Int
    var verseStart: Int?
    var verseEnd: Int?
    /// For ranges that cross chapters, e.g. John 3:16-4:2.
    var endChapter: Int?

    var id: String { display }
    var book: BibleBook { BibleBooks.book(number: bookNumber)! }

    var display: String {
        var s = "\(book.name) \(chapter)"
        if let v = verseStart {
            s += ":\(v)"
            if let ec = endChapter, ec != chapter { s += "-\(ec):\(verseEnd ?? 1)" }
            else if let e = verseEnd, e != v { s += "-\(e)" }
        }
        return s
    }

    /// e.g. "JHN.3.16-JHN.3.18" for API.Bible.
    var usfmPassageID: String {
        let b = book.usfm
        guard let v = verseStart else { return "\(b).\(chapter)" }
        let start = "\(b).\(chapter).\(v)"
        let endCh = endChapter ?? chapter
        let endV = verseEnd ?? v
        if endCh == chapter && endV == v { return start }
        return "\(start)-\(b).\(endCh).\(endV)"
    }
}

enum ReferenceParser {
    private static let typedRegex: NSRegularExpression = {
        let pattern = #"(?i)(?<![a-z])("# + BibleBooks.aliasPattern +
            #")\.?\s*(\d{1,3})(?:\s*[:.]\s*(\d{1,3})(?:\s*[-–—]\s*(\d{1,3})(?:\s*[:.]\s*(\d{1,3}))?)?)?(?![a-z])"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Parses typed references: "jn 3:16", "Gen 32", "1 cor 13:4-7", "Psalm 23", "John 3:16-4:2".
    static func parse(_ text: String) -> BibleReference? { parseAll(text).first }

    static func parseAll(_ input: String) -> [BibleReference] {
        // "jn 3 16" → "jn 3:16"
        let text = input.replacingOccurrences(of: #"([a-zA-Z]\.?\s*\d{1,3})\s+(\d{1,3})\b"#, with: "$1:$2",
                                              options: .regularExpression)
        let ns = text as NSString
        return typedRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let bookText = g(1), let book = BibleBooks.book(named: bookText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)) ?? BibleBooks.book(named: bookText.replacingOccurrences(of: " ", with: "")),
                  var ch = g(2).flatMap(Int.init), ch >= 1 else { return nil }
            var verseFromNumber = false
            if book.chapters == 1, g(3) == nil, ch > 1 || g(4) != nil {
                // Jude, Obadiah, Philemon, 2 John, 3 John have no chapters: "Jude 3" is verse 3 of chapter 1.
                verseFromNumber = true
            }
            guard verseFromNumber || ch <= book.chapters else { return nil }
            var ref = BibleReference(bookNumber: book.number, chapter: verseFromNumber ? 1 : ch)
            if verseFromNumber { ref.verseStart = ch; ch = 1 }
            else { ref.verseStart = g(3).flatMap(Int.init) }
            if verseFromNumber {
                if let e = g(4).flatMap(Int.init) { ref.verseEnd = e }      // Jude 3-5
            } else if let a = g(4).flatMap(Int.init) {
                if let b = g(5).flatMap(Int.init) {
                    ref.endChapter = a; ref.verseEnd = b      // 3:16-4:2
                } else {
                    ref.verseEnd = a                           // 3:16-18
                }
            }
            if let s = ref.verseStart, let e = ref.verseEnd, ref.endChapter == nil, e < s { ref.verseEnd = nil }
            return ref
        }
    }
}

/// Converts spoken numbers and phrases into something the typed parser understands.
enum SpokenNormalizer {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinalPrefixes: [String: String] = [
        "first": "1", "1st": "1", "second": "2", "2nd": "2", "third": "3", "3rd": "3",
    ]

    /// "turn to first corinthians chapter thirteen verse four through seven" → "turn to 1 corinthians 13:4-7"
    static func normalize(_ input: String) -> String {
        var words = input.lowercased()
            .replacingOccurrences(of: #"[,;!?]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)

        // Ordinals before numbered books ("first john", "second kings").
        let numberedBooks: Set<String> = ["samuel", "kings", "chronicles", "corinthians", "thessalonians", "timothy",
                                          "peter", "john", "jn"]
        var i = 0
        while i < words.count - 1 {
            if let n = ordinalPrefixes[words[i]], numberedBooks.contains(words[i + 1]) { words[i] = n }
            // "one john", "two timothy" when spoken as numbers.
            else if ["one", "two", "three"].contains(words[i]), numberedBooks.contains(words[i + 1]),
                    i == 0 || !["chapter", "verse", "verses"].contains(words[i - 1]) {
                words[i] = String(units[words[i]]!)
            }
            i += 1
        }

        // Collapse number words: "one hundred nineteen" → 119, "thirty two" → 32.
        var out: [String] = []
        var acc: Int? = nil
        func flush() { if let a = acc { out.append(String(a)); acc = nil } }
        for w in words {
            if w == "hundred", let a = acc { acc = min(a * 100, 100_000); continue }
            if w == "and", acc != nil { continue }
            if let t = tens[w] {
                if let a = acc, a < 100 { flush() }
                acc = (acc ?? 0) + t
                continue
            }
            if let u = units[w] {
                if let a = acc, a >= 20, a % 10 == 0 || a >= 100 { acc = a + u } else { flush(); acc = u }
                continue
            }
            flush()
            out.append(w)
        }
        flush()

        var s = out.joined(separator: " ")
        s = s.replacingOccurrences(of: #"\bpsalm\b"#, with: "psalms", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bchapter\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d+)\s+(?:verses?|v)\s+(\d+)"#, with: "$1:$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d+):(\d+)\s+(?:through|thru|to|and)\s+(\d+)"#, with: "$1:$2-$3", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([a-z]) (\d{1,3}) (\d{1,3})\b"#, with: "$1 $2:$3", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bsong of solomon\b"#, with: "song of songs", options: .regularExpression)
        return s
    }
}
