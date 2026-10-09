import Foundation

/// A parsed chord symbol: root + quality/extension + optional slash bass.
struct Chord: Hashable {
    var root: Int          // pitch class 0...11, C = 0
    var rootName: String   // as written ("F#", "Bb")
    var suffix: String     // everything after the root ("m7", "sus4", "maj7", "")
    var bass: Int?
    var bassName: String?

    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    static func pitchClass(_ s: String) -> Int? {
        guard let first = s.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first).uppercased()] else { return nil }
        var v = base
        for c in s.dropFirst() {
            if c == "#" || c == "♯" { v += 1 } else if c == "b" || c == "♭" { v -= 1 } else { break }
        }
        return (v + 12) % 12
    }

    private static let pattern = try! NSRegularExpression(pattern:
        #"^([A-G](?:#|b|♯|♭)?)((?:maj|min|m|M|dim|aug|sus|add|°|ø|\+|-|Δ|\d|\(|\)|b|#|♭|♯)*)(?:/([A-G](?:#|b|♯|♭)?))?$"#)

    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t()[]|"))
        let ns = s as NSString
        guard !s.isEmpty, let m = Self.pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let r = g(1), let pc = Self.pitchClass(r) else { return nil }
        root = pc
        rootName = r
        suffix = g(2) ?? ""
        bassName = g(3)
        bass = bassName.flatMap(Self.pitchClass)
    }

    var isMinor: Bool {
        let s = suffix
        return (s.hasPrefix("m") && !s.hasPrefix("maj")) || s.hasPrefix("min") || s.hasPrefix("-")
    }

    /// The suffix with the minor marker removed (for Nashville, minor is written separately).
    var extensionPart: String {
        var s = suffix
        if s.hasPrefix("min") { s.removeFirst(3) } else if s.hasPrefix("maj") { return s } else if s.hasPrefix("m") || s.hasPrefix("-") { s.removeFirst() }
        return s
    }

    /// Whether a token on a chart looks like a chord (not a lyric word like "A" or "Em…" in a sentence).
    static func isChordToken(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: CharacterSet(charactersIn: "()[]|,"))
        if s.isEmpty { return false }
        if ["N.C.", "NC", "N.C", "x2", "x3", "x4", "2x", "3x", "4x", "/", "-", "|", "%"].contains(s) { return true }
        return Chord(s) != nil
    }
}

struct MusicKey: Hashable {
    var tonic: Int
    var minor: Bool
    var name: String

    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let c = Chord(s) else { return nil }
        tonic = c.root
        minor = c.isMinor
        name = s
    }

    /// Worship charts number minor keys from the relative major (Em → G, so Em = 6m).
    var majorTonic: Int { minor ? (tonic + 3) % 12 : tonic }

    /// Flat keys spell accidentals with flats.
    var prefersFlats: Bool {
        let flatMajors: Set<Int> = [5, 10, 3, 8, 1, 6] // F Bb Eb Ab Db Gb
        return flatMajors.contains(majorTonic) || name.contains("b")
    }
}

enum Nashville {
    static let degreeNames: [Int: String] = [0: "1", 1: "b2", 2: "2", 3: "b3", 4: "3", 5: "4", 6: "b5", 7: "5", 8: "b6", 9: "6", 10: "b7", 11: "7"]

    static func degree(_ pc: Int, in key: MusicKey) -> String {
        degreeNames[(pc - key.majorTonic + 12) % 12]!
    }

    /// "D/F#" in G → "5/7", "Em7" → "6m7", "Cmaj7" → "4maj7", "Bb" in G → "b3".
    static func number(for chordText: String, key: MusicKey, minorSymbol: String = "m") -> String {
        guard let c = Chord(chordText) else { return chordText }
        var out = degree(c.root, in: key)
        if c.isMinor { out += minorSymbol }
        out += c.extensionPart
        if let b = c.bass { out += "/" + degree(b, in: key) }
        return out
    }

    /// Converts a Nashville number back into a letter chord in a key ("5/7" in G → "D/F#").
    static func letter(for number: String, key: MusicKey) -> String? {
        let parts = number.split(separator: "/", maxSplits: 1).map(String.init)
        func parseDegree(_ s: String) -> (pc: Int, rest: String)? {
            var str = Substring(s)
            var accidental = 0
            while let f = str.first, f == "b" || f == "#" { accidental += f == "#" ? 1 : -1; str = str.dropFirst() }
            guard let d = str.first, let n = Int(String(d)), (1...7).contains(n) else { return nil }
            let steps = [0, 2, 4, 5, 7, 9, 11][n - 1]
            return ((key.majorTonic + steps + accidental + 24) % 12, String(str.dropFirst()))
        }
        guard let (rootPC, rest) = parseDegree(parts[0]) else { return nil }
        let names = key.prefersFlats ? Chord.flatNames : Chord.sharpNames
        var out = names[rootPC] + rest.replacingOccurrences(of: "-", with: "m")
        if parts.count > 1, let (bassPC, _) = parseDegree(parts[1]) { out += "/" + names[bassPC] }
        return out
    }

    static func transpose(_ chordText: String, by semitones: Int, flats: Bool) -> String {
        guard let c = Chord(chordText) else { return chordText }
        let names = flats ? Chord.flatNames : Chord.sharpNames
        var out = names[(c.root + semitones + 120) % 12] + c.suffix
        if let b = c.bass { out += "/" + names[(b + semitones + 120) % 12] }
        return out
    }

    /// Guesses the key from a list of chords: the major key whose diatonic set covers most chords,
    /// breaking ties toward the first and last chord's root.
    static func guessKey(_ chords: [String]) -> String? {
        let parsed = chords.compactMap(Chord.init)
        guard !parsed.isEmpty else { return nil }
        var best = (score: -1.0, tonic: 0)
        for tonic in 0..<12 {
            let diatonic: [Int: Bool] = [0: false, 2: true, 4: true, 5: false, 7: false, 9: true, 11: true] // value = expected minor
            var score = 0.0
            for c in parsed {
                let deg = (c.root - tonic + 12) % 12
                if let expectMinor = diatonic[deg] { score += expectMinor == c.isMinor ? 1 : 0.5 }
            }
            if parsed.first!.root == tonic { score += 0.75 }
            if parsed.last!.root == tonic { score += 0.75 }
            if score > best.score { best = (score, tonic) }
        }
        let flats: Set<Int> = [5, 10, 3, 8, 1, 6]
        return (flats.contains(best.tonic) ? Chord.flatNames : Chord.sharpNames)[best.tonic]
    }
}

/// ChordPro inline format ("[G]Amazing [C]grace") ⇄ lyric text + placements.
enum ChordPro {
    static func encode(text: String, chords: [ChordPlacement]) -> String {
        text.components(separatedBy: "\n").enumerated().map { i, line in
            var chars = Array(line)
            // Insert from the right so earlier indices stay valid.
            for p in chords.filter({ $0.line == i }).sorted(by: { $0.index > $1.index }) {
                let at = min(max(0, p.index), chars.count)
                chars.insert(contentsOf: Array("[\(p.chord)]"), at: at)
            }
            return String(chars)
        }.joined(separator: "\n")
    }

    static func decode(_ s: String) -> (text: String, chords: [ChordPlacement]) {
        var lines: [String] = []
        var chords: [ChordPlacement] = []
        for (i, raw) in s.components(separatedBy: "\n").enumerated() {
            var out = ""
            var idx = raw.startIndex
            while idx < raw.endIndex {
                if raw[idx] == "[", let close = raw[idx...].firstIndex(of: "]") {
                    let name = String(raw[raw.index(after: idx)..<close]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { chords.append(ChordPlacement(line: i, index: out.count, chord: name)) }
                    idx = raw.index(after: close)
                } else {
                    out.append(raw[idx])
                    idx = raw.index(after: idx)
                }
            }
            lines.append(out)
        }
        return (lines.joined(separator: "\n"), chords)
    }
}
