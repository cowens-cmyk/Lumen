import Foundation

struct ScriptureDetection: Identifiable, Hashable {
    var id = UUID()
    var reference: BibleReference
    var heard: String
    var at: Date
    var strong: Bool
}

/// Finds Bible references in what the pastor says ("turn with me to Genesis chapter thirty-two").
struct ScriptureDetector {
    private var recent: [String: Date] = [:]

    private static let spokenRegex: NSRegularExpression = {
        var names = BibleBooks.all.map { $0.name.lowercased() }
        names += ["psalm", "song of solomon", "revelations"]
        let alt = names.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        return try! NSRegularExpression(pattern: #"(?i)\b(?:the\s+book\s+of\s+)?("# + alt +
                                        #")\s+(\d{1,3})(?:\s*:\s*(\d{1,3})(?:\s*-\s*(\d{1,3}))?)?"#)
    }()

    private static let cues = ["turn to", "turn with me", "open your bible", "open to", "chapter", "verse", "book of",
                               "reading from", "read from", "it says in", "look at", "go to", "found in", "scripture"]

    /// Returns new references found in this transcript fragment (deduplicated over 90 seconds).
    mutating func scan(_ transcript: String, now: Date = Date()) -> [ScriptureDetection] {
        let tail = transcript.split(separator: " ").suffix(30).joined(separator: " ")
        let lowerRaw = tail.lowercased()
        let text = SpokenNormalizer.normalize(tail)
        let ns = text as NSString
        var out: [ScriptureDetection] = []
        for m in Self.spokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let bookName = g(1), let book = BibleBooks.book(named: bookName.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)),
                  let num = g(2).flatMap(Int.init), num >= 1 else { continue }
            // Single-chapter books (Jude, Philemon…): "Jude 3" is verse 3.
            let verseFromNumber = book.chapters == 1 && num > 1 && g(3) == nil
            guard verseFromNumber || num <= book.chapters else { continue }
            let ch = verseFromNumber ? 1 : num
            let hasVerse = g(3) != nil || verseFromNumber
            let hasCue = Self.cues.contains { lowerRaw.contains($0) }
            // "Mark 5" or "Acts 2" in normal speech needs a verse or a cue to count.
            if BibleBooks.ambiguousSpoken.contains(book.name), !hasVerse, !hasCue { continue }
            var ref = BibleReference(bookNumber: book.number, chapter: ch)
            ref.verseStart = verseFromNumber ? num : g(3).flatMap(Int.init)
            ref.verseEnd = g(4).flatMap(Int.init)
            let key = ref.display
            if let last = recent[key], now.timeIntervalSince(last) < 90 { continue }
            // A bare chapter that's later refined with a verse should still surface — key differs, fine.
            recent[key] = now
            out.append(ScriptureDetection(reference: ref, heard: tail, at: now, strong: hasVerse || hasCue))
        }
        return out
    }
}
