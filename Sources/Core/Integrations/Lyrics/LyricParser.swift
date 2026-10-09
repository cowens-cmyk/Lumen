import Foundation

/// Turns lyric text from Planning Center / SongSelect / pasted text into grouped slides.
enum LyricParser {
    static let sectionWords = [
        "verse", "pre-chorus", "prechorus", "pre chorus", "chorus", "refrain", "bridge", "tag", "intro", "outro",
        "ending", "interlude", "instrumental", "vamp", "turnaround", "misc", "breakdown", "post-chorus",
        "postchorus", "channel", "coda", "hook", "spontaneous", "outro",
    ]

    struct Section {
        var name: String
        var lines: [String]
        /// Slide breaks the author placed explicitly (blank lines inside a section).
        var explicitSlides: [[String]]
    }

    /// Returns a canonical section name if the line is a heading like "[Verse 1]", "CHORUS:", "Pre-Chorus 2".
    static func heading(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count <= 32 else { return nil }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            // Bracketed lines are always headings, whatever the name ("[Welcome]", "[Spontaneous]").
            let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : canonical(inner)
        }
        if line.hasSuffix(":") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        // Allow "(x2)" / "x2" suffixes on headings.
        let stripped = lower.replacingOccurrences(of: #"\s*\(?x\d\)?$"#, with: "", options: .regularExpression)
        for w in sectionWords where stripped.hasPrefix(w) {
            let rest = stripped.dropFirst(w.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.allSatisfy({ $0.isNumber || $0 == " " || $0 == "." || $0 == "a" || $0 == "b" }) {
                return canonical(line.replacingOccurrences(of: #"\s*\(?[xX]\d\)?$"#, with: "", options: .regularExpression))
            }
        }
        return nil
    }

    static func canonical(_ name: String) -> String {
        name.split(separator: " ").map { part -> String in
            let s = String(part)
            if s.contains("-") {
                return s.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: "-")
            }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Lines that are only chords ("G  D/F#  Em  C") are dropped.
    static func isChordLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return false }
        let chord = #"^[A-G](#|b)?(m|maj|min|sus|dim|aug|add)?\d*(sus\d*|add\d*)?(\/[A-G](#|b)?)?$"#
        return tokens.allSatisfy { $0.range(of: chord, options: .regularExpression) != nil || $0 == "|" || $0 == "-" }
    }

    static func sections(from text: String) -> [Section] {
        var out: [Section] = []
        var current: Section? = nil
        var block: [String] = []

        func flushBlock() {
            guard !block.isEmpty else { return }
            if current == nil { current = Section(name: "Verse 1", lines: [], explicitSlides: []) }
            current!.lines += block
            current!.explicitSlides.append(block)
            block = []
        }
        func flushSection() {
            flushBlock()
            if let c = current, !c.lines.isEmpty { out.append(c) }
            current = nil
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("ccli song") || line.lowercased().hasPrefix("ccli license") { break }
            if let h = heading(line) {
                flushSection()
                current = Section(name: h, lines: [], explicitSlides: [])
                continue
            }
            if line.isEmpty { flushBlock(); continue }
            if isChordLine(line) { continue }
            block.append(line)
        }
        flushSection()
        return out
    }

    static func slides(for section: Section, maxLines: Int) -> [[String]] {
        let maxLines = max(1, maxLines)
        // Respect explicit breaks when the author used them and they're reasonably sized.
        if section.explicitSlides.count > 1, section.explicitSlides.allSatisfy({ $0.count <= maxLines * 2 }) {
            return section.explicitSlides
        }
        return stride(from: 0, to: section.lines.count, by: maxLines).map {
            Array(section.lines[$0..<min($0 + maxLines, section.lines.count)])
        }
    }

    static func presentation(name: String, kind: PresentationKind = .song, text: String, maxLines: Int = 2,
                             sequence: [String] = []) -> Presentation {
        var p = Presentation(name: name, kind: kind)
        apply(text: text, to: &p, maxLines: maxLines, sequence: sequence)
        return p
    }

    /// Rebuilds groups from text, keeping existing group IDs (and colors) where names match.
    static func apply(text: String, to p: inout Presentation, maxLines: Int, sequence: [String] = []) {
        let secs = sections(from: text)
        var groups: [SlideGroup] = []
        var seen: [String: Int] = [:]
        for sec in secs {
            var name = sec.name
            // Same heading twice without a number (e.g. two "Chorus" blocks with identical text) → one group.
            if let idx = seen[name.lowercased()] {
                if groups[idx].slides.map(\.text) == slides(for: sec, maxLines: maxLines).map({ $0.joined(separator: "\n") }) {
                    continue
                }
                name += " \(groups.filter { $0.name.lowercased().hasPrefix(sec.name.lowercased()) }.count + 1)"
            }
            let existing = p.groups.first { $0.name.lowercased() == name.lowercased() }
            let slideTexts = slides(for: sec, maxLines: maxLines).map { $0.joined(separator: "\n") }
            let slides = slideTexts.enumerated().map { i, t -> Slide in
                var s = existing?.slides[safe: i] ?? Slide()
                s.text = t
                return s
            }
            groups.append(SlideGroup(id: existing?.id ?? UUID(), name: name,
                                     color: existing?.color ?? SlideGroup.color(for: name), slides: slides))
            seen[sec.name.lowercased()] = groups.count - 1
        }
        p.groups = groups
        p.arrangement = sequence.isEmpty ? [] : arrangement(from: sequence, groups: groups)
    }

    static func normalizeSectionKey(_ s: String) -> String {
        var k = s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        let shorts = ["v": "verse", "c": "chorus", "pc": "prechorus", "b": "bridge", "t": "tag", "i": "intro",
                      "e": "ending", "o": "outro", "it": "interlude", "ch": "chorus", "br": "bridge", "pre": "prechorus"]
        if let m = k.range(of: #"^[a-z]+"#, options: .regularExpression) {
            let letters = String(k[m])
            if let full = shorts[letters] { k = full + k[m.upperBound...] }
        }
        return k
    }

    /// Maps a Planning Center sequence like ["Verse 1", "Chorus", "V2", "C"] to group IDs.
    static func arrangement(from sequence: [String], groups: [SlideGroup]) -> [UUID] {
        let keyed = groups.map { (normalizeSectionKey($0.name), $0.id) }
        return sequence.compactMap { item in
            let k = normalizeSectionKey(item)
            if let exact = keyed.first(where: { $0.0 == k }) { return exact.1 }
            // "Chorus" matches "Chorus 1"; "Verse" matches "Verse 1".
            if let pref = keyed.first(where: { $0.0.hasPrefix(k) || k.hasPrefix($0.0) }) { return pref.1 }
            return nil
        }
    }

    /// Serializes a presentation back to editable text.
    static func text(for p: Presentation) -> String {
        p.groups.map { g in
            "[\(g.name)]\n" + g.slides.map(\.text).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    // MARK: File formats

    /// SongSelect .usr files.
    static func parseUSR(_ text: String) -> (title: String, author: String, copyright: String, ccli: String, lyrics: String) {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            if let eq = line.firstIndex(of: "=") {
                fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        let names = (fields["Fields"] ?? "").components(separatedBy: "/t")
        let words = (fields["Words"] ?? "").components(separatedBy: "/t")
        var lyrics = ""
        for (i, w) in words.enumerated() {
            let name = names[safe: i] ?? "Verse \(i + 1)"
            lyrics += "[\(name)]\n" + w.replacingOccurrences(of: "/n", with: "\n") + "\n\n"
        }
        let ccli = text.range(of: #"\[S A?(\d+)\]"#, options: .regularExpression).map {
            String(text[$0]).filter(\.isNumber)
        } ?? ""
        return (fields["Title"] ?? "Untitled", fields["Author"] ?? "", fields["Copyright"] ?? "", ccli, lyrics)
    }

    /// SongSelect / generic .txt exports: first line is the title.
    static func parseTXT(_ text: String, fallbackTitle: String) -> (title: String, ccli: String, lyrics: String) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var title = fallbackTitle
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty, heading(first) == nil {
            title = first
            lines.removeFirst()
        }
        let ccli = text.range(of: #"CCLI Song #\s*(\d+)"#, options: .regularExpression).map {
            String(text[$0]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        } ?? ""
        return (title, ccli, lines.joined(separator: "\n"))
    }

    /// OpenLyrics XML (used by OpenLP, EasyWorship exports, many others).
    static func parseOpenLyrics(_ data: Data) -> (title: String, lyrics: String, order: [String])? {
        let d = OpenLyricsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = d
        guard parser.parse(), !d.verses.isEmpty else { return nil }
        func label(_ key: String) -> String {
            let map = ["v": "Verse", "c": "Chorus", "b": "Bridge", "p": "Pre-Chorus", "e": "Ending", "i": "Intro", "o": "Outro"]
            let letter = String(key.prefix(1)).lowercased()
            let num = key.dropFirst().filter(\.isNumber)
            return (map[letter] ?? canonical(key)) + (num.isEmpty ? "" : " \(num)")
        }
        let lyrics = d.verses.map { "[\(label($0.0))]\n\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
        let order = d.verseOrder.split(separator: " ").map { label(String($0)) }
        return (d.title.isEmpty ? "Untitled" : d.title, lyrics, order)
    }
}

private final class OpenLyricsDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var verseOrder = ""
    var verses: [(String, String)] = []
    private var path: [String] = []
    private var currentVerse: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        path.append(name)
        if name == "verse" { currentVerse = attributes["name"] ?? "v\(verses.count + 1)"; buffer = "" }
        if name == "br" { buffer += "\n" }
        if name == "lines", !buffer.isEmpty, !buffer.hasSuffix("\n\n") { buffer += "\n\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path.last == "title", title.isEmpty { title = string.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if path.last == "verseOrder" { verseOrder += string }
        else if currentVerse != nil, path.contains("lines") {
            buffer += string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        path.removeLast()
        if name == "verse", let v = currentVerse {
            let cleaned = buffer.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            verses.append((v, cleaned))
            currentVerse = nil
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
