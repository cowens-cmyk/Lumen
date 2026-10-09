import Foundation

struct BibleBook: Hashable {
    let number: Int      // 1...66
    let name: String
    let usfm: String
    let chapters: Int
    let aliases: [String]
}

enum BibleBooks {
    // (name, USFM, chapters, extra aliases)
    private static let raw: [(String, String, Int, [String])] = [
        ("Genesis", "GEN", 50, ["gen", "ge", "gn"]),
        ("Exodus", "EXO", 40, ["exo", "ex", "exod"]),
        ("Leviticus", "LEV", 27, ["lev", "le", "lv"]),
        ("Numbers", "NUM", 36, ["num", "nu", "nm"]),
        ("Deuteronomy", "DEU", 34, ["deut", "deu", "dt"]),
        ("Joshua", "JOS", 24, ["josh", "jos"]),
        ("Judges", "JDG", 21, ["judg", "jdg", "jg"]),
        ("Ruth", "RUT", 4, ["rut", "ru"]),
        ("1 Samuel", "1SA", 31, ["1 sam", "1sam", "1 sa", "1sa"]),
        ("2 Samuel", "2SA", 24, ["2 sam", "2sam", "2 sa", "2sa"]),
        ("1 Kings", "1KI", 22, ["1 kgs", "1kgs", "1 ki", "1ki"]),
        ("2 Kings", "2KI", 25, ["2 kgs", "2kgs", "2 ki", "2ki"]),
        ("1 Chronicles", "1CH", 29, ["1 chron", "1chron", "1 chr", "1chr", "1 ch"]),
        ("2 Chronicles", "2CH", 36, ["2 chron", "2chron", "2 chr", "2chr", "2 ch"]),
        ("Ezra", "EZR", 10, ["ezr"]),
        ("Nehemiah", "NEH", 13, ["neh", "ne"]),
        ("Esther", "EST", 10, ["esth", "est"]),
        ("Job", "JOB", 42, ["jb"]),
        ("Psalms", "PSA", 150, ["psalm", "ps", "psa", "pss"]),
        ("Proverbs", "PRO", 31, ["prov", "pro", "prv", "pr", "proverb"]),
        ("Ecclesiastes", "ECC", 12, ["eccl", "ecc", "eccles", "qoh"]),
        ("Song of Songs", "SNG", 8, ["song of solomon", "song", "sos", "canticles"]),
        ("Isaiah", "ISA", 66, ["isa", "is"]),
        ("Jeremiah", "JER", 52, ["jer", "je"]),
        ("Lamentations", "LAM", 5, ["lam", "la"]),
        ("Ezekiel", "EZK", 48, ["ezek", "eze", "ezk"]),
        ("Daniel", "DAN", 12, ["dan", "da", "dn"]),
        ("Hosea", "HOS", 14, ["hos", "ho"]),
        ("Joel", "JOL", 3, ["joe", "jl"]),
        ("Amos", "AMO", 9, ["amo", "am"]),
        ("Obadiah", "OBA", 1, ["obad", "ob"]),
        ("Jonah", "JON", 4, ["jon", "jnh"]),
        ("Micah", "MIC", 7, ["mic", "mi"]),
        ("Nahum", "NAM", 3, ["nah", "na"]),
        ("Habakkuk", "HAB", 3, ["hab"]),
        ("Zephaniah", "ZEP", 3, ["zeph", "zep"]),
        ("Haggai", "HAG", 2, ["hag"]),
        ("Zechariah", "ZEC", 14, ["zech", "zec"]),
        ("Malachi", "MAL", 4, ["mal"]),
        ("Matthew", "MAT", 28, ["matt", "mat", "mt"]),
        ("Mark", "MRK", 16, ["mrk", "mk", "mar"]),
        ("Luke", "LUK", 24, ["luk", "lk"]),
        ("John", "JHN", 21, ["jhn", "jn", "joh"]),
        ("Acts", "ACT", 28, ["act", "ac"]),
        ("Romans", "ROM", 16, ["rom", "ro", "rm"]),
        ("1 Corinthians", "1CO", 16, ["1 cor", "1cor", "1 co", "1co"]),
        ("2 Corinthians", "2CO", 13, ["2 cor", "2cor", "2 co", "2co"]),
        ("Galatians", "GAL", 6, ["gal", "ga"]),
        ("Ephesians", "EPH", 6, ["eph", "ephes"]),
        ("Philippians", "PHP", 4, ["phil", "php", "pp"]),
        ("Colossians", "COL", 4, ["col"]),
        ("1 Thessalonians", "1TH", 5, ["1 thess", "1thess", "1 th", "1th"]),
        ("2 Thessalonians", "2TH", 3, ["2 thess", "2thess", "2 th", "2th"]),
        ("1 Timothy", "1TI", 6, ["1 tim", "1tim", "1 ti", "1ti"]),
        ("2 Timothy", "2TI", 4, ["2 tim", "2tim", "2 ti", "2ti"]),
        ("Titus", "TIT", 3, ["tit"]),
        ("Philemon", "PHM", 1, ["philem", "phm"]),
        ("Hebrews", "HEB", 13, ["heb"]),
        ("James", "JAS", 5, ["jas", "jm"]),
        ("1 Peter", "1PE", 5, ["1 pet", "1pet", "1 pe", "1pe"]),
        ("2 Peter", "2PE", 3, ["2 pet", "2pet", "2 pe", "2pe"]),
        ("1 John", "1JN", 5, ["1 jn", "1jn", "1 jhn", "1jo"]),
        ("2 John", "2JN", 1, ["2 jn", "2jn", "2 jhn", "2jo"]),
        ("3 John", "3JN", 1, ["3 jn", "3jn", "3 jhn", "3jo"]),
        ("Jude", "JUD", 1, ["jud", "jde"]),
        ("Revelation", "REV", 22, ["rev", "re", "revelations", "the revelation"]),
    ]

    static let all: [BibleBook] = raw.enumerated().map { i, r in
        var aliases = Set([r.0.lowercased()] + r.3)
        // "1 John" → "1john" as well.
        aliases.insert(r.0.lowercased().replacingOccurrences(of: " ", with: ""))
        return BibleBook(number: i + 1, name: r.0, usfm: r.1, chapters: r.2, aliases: Array(aliases))
    }

    /// Books whose names are common English words; spoken detection needs extra evidence for these.
    static let ambiguousSpoken: Set<String> = ["Mark", "Job", "Acts", "Numbers", "James", "Jude", "Song of Songs", "Amos", "Ruth"]

    static func book(named s: String) -> BibleBook? {
        let k = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return all.first { $0.aliases.contains(k) }
    }

    static func book(number: Int) -> BibleBook? { all[safe: number - 1] }

    /// Alias alternation for regexes, longest first so "1 john" wins over "john".
    static let aliasPattern: String = {
        let aliases = all.flatMap(\.aliases).sorted { $0.count > $1.count }
        return aliases.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s*"#) }
            .joined(separator: "|")
    }()
}
