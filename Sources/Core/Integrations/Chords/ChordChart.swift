import AppKit
import Foundation
import PDFKit
import Vision

/// A chord chart reduced to what Lumen needs: sections of lyric lines with chords at character offsets.
struct ChordChart: Hashable {
    struct Line: Hashable {
        var lyric: String
        var chords: [(index: Int, chord: String)]
        static func == (a: Line, b: Line) -> Bool {
            a.lyric == b.lyric && a.chords.map(\.index) == b.chords.map(\.index) && a.chords.map(\.chord) == b.chords.map(\.chord)
        }
        func hash(into h: inout Hasher) { h.combine(lyric); h.combine(chords.map(\.chord)) }
    }
    struct Section: Hashable {
        var name: String
        var lines: [Line]
    }

    var title: String = ""
    var key: String?
    /// Section order if the chart prints one ("Intro > Verse 1 > Chorus …").
    var roadmap: [String] = []
    var sections: [Section] = []

    var allChords: [String] { sections.flatMap { $0.lines.flatMap { $0.chords.map(\.chord) } } }
    var lyricLines: [(section: String, line: Line)] {
        sections.flatMap { s in s.lines.filter { !$0.lyric.trimmingCharacters(in: .whitespaces).isEmpty }.map { (s.name, $0) } }
    }
}

/// A glyph with its horizontal position, from a PDF, OCR, or a monospaced text column.
struct PlacedGlyph {
    var char: Character
    var x: CGFloat
    var width: CGFloat
}

struct PlacedLine {
    var y: CGFloat
    var glyphs: [PlacedGlyph]   // sorted by x, whitespace removed
    var height: CGFloat

    /// Rebuilds the line as text, inserting a single space wherever glyphs are visibly apart,
    /// and returns each character's x so chords can be dropped onto the right letter.
    func text() -> (string: String, xs: [CGFloat], tokens: [(text: String, x: CGFloat)]) {
        let t = layout()
        return (t.string, t.xs, t.tokens)
    }

    /// Like `text()`, plus each character's width so word ends are exact.
    func layout() -> (string: String, xs: [CGFloat], widths: [CGFloat], tokens: [(text: String, x: CGFloat)]) {
        var s = ""
        var xs: [CGFloat] = []
        var ws: [CGFloat] = []
        var tokens: [(String, CGFloat)] = []
        var current = ""
        var currentX: CGFloat = 0
        let gapThreshold = max(1, height * 0.2)
        for (i, g) in glyphs.enumerated() {
            if i > 0 {
                let prev = glyphs[i - 1]
                if g.x - (prev.x + prev.width) >= gapThreshold {
                    s.append(" "); xs.append(prev.x + prev.width); ws.append(g.x - (prev.x + prev.width))
                    tokens.append((current, currentX)); current = ""
                }
            }
            if current.isEmpty { currentX = g.x }
            current.append(g.char)
            s.append(g.char); xs.append(g.x); ws.append(g.width)
        }
        if !current.isEmpty { tokens.append((current, currentX)) }
        return (s, xs, ws, tokens)
    }
}

enum ChordChartReader {
    enum ReadError: LocalizedError {
        case unreadable, noChords
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read any text from that file."
            case .noChords: "No chord lines were found. Is this a lyrics-only sheet?"
            }
        }
    }

    // MARK: Entry points

    static func read(url: URL) throws -> ChordChart {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ReadError.unreadable }
            return try read(pdf: doc, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try read(text: text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    static func read(pdf: PDFDocument, fallbackTitle: String) throws -> ChordChart {
        var lines: [PlacedLine] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            var pageLines = textLines(page)
            if pageLines.filter({ !$0.glyphs.isEmpty }).count < 2 {
                pageLines = ocrLines(page)   // scanned chart
            }
            lines += pageLines
        }
        guard !lines.isEmpty else { throw ReadError.unreadable }
        let chart = parse(lines, fallbackTitle: fallbackTitle)
        if chart.allChords.isEmpty { throw ReadError.noChords }
        return chart
    }

    /// Plain text: ChordPro ("[G]Amazing") or chords-over-lyrics in a monospaced layout.
    static func read(text: String, fallbackTitle: String) throws -> ChordChart {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        let chordPro = normalized.range(of: #"\[[A-G][#b]?[^\]\s]{0,8}\]"#, options: .regularExpression) != nil
        let chart = chordPro ? parseChordPro(normalized, fallbackTitle: fallbackTitle)
                             : parse(monospaceLines(normalized), fallbackTitle: fallbackTitle)
        if chart.allChords.isEmpty { throw ReadError.noChords }
        return chart
    }

    // MARK: Geometry extraction

    static func monospaceLines(_ text: String) -> [PlacedLine] {
        text.components(separatedBy: "\n").enumerated().map { row, line in
            let glyphs = Array(line).enumerated().compactMap { col, c -> PlacedGlyph? in
                c.isWhitespace ? nil : PlacedGlyph(char: c, x: CGFloat(col), width: 1)
            }
            // Height 5 makes the space threshold 1 column: any gap of 1+ columns is a word break.
            return PlacedLine(y: CGFloat(-row), glyphs: glyphs, height: 4.99)
        }
    }

    /// Text-based PDF: every glyph with its bounds, grouped into visual lines, split into columns if needed.
    static func textLines(_ page: PDFPage) -> [PlacedLine] {
        // `page.string` and `characterBounds(at:)` disagree on indexing after line breaks, so walk the
        // page's own character indices and ask a one-character selection for both the glyph and its box.
        let count = page.numberOfCharacters
        guard count > 0 else { return [] }
        var glyphs: [(PlacedGlyph, CGRect)] = []
        var last: (Character, CGRect)?
        for i in 0..<count {
            guard let sel = page.selection(for: NSRange(location: i, length: 1)),
                  let str = sel.string, str.count == 1, let c = str.first,
                  !c.isWhitespace, !c.isNewline else { continue }
            let r = sel.bounds(for: page)
            guard r.width > 0, r.height > 0 else { continue }
            // Line breaks can echo the previous glyph; skip exact repeats.
            if let l = last, l.0 == c, abs(l.1.minX - r.minX) < 0.5, abs(l.1.minY - r.minY) < 0.5 { continue }
            last = (c, r)
            glyphs.append((PlacedGlyph(char: c, x: r.minX, width: r.width), r))
        }
        return group(glyphs, pageWidth: page.bounds(for: .mediaBox).width)
    }

    /// Scanned PDF: OCR with per-character boxes.
    static func ocrLines(_ page: PDFPage) -> [PlacedLine] {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2400 / max(bounds.width, 1)
        let img = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false   // keep "Em7", "D/F#" intact
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        var glyphs: [(PlacedGlyph, CGRect)] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            var idx = s.startIndex
            while idx < s.endIndex {
                let next = s.index(after: idx)
                let c = s[idx]
                if !c.isWhitespace, let box = try? cand.boundingBox(for: idx..<next)?.boundingBox {
                    let r = CGRect(x: box.minX * bounds.width, y: box.minY * bounds.height,
                                   width: box.width * bounds.width, height: max(box.height * bounds.height, 1))
                    glyphs.append((PlacedGlyph(char: c, x: r.minX, width: r.width), r))
                }
                idx = next
            }
        }
        return group(glyphs, pageWidth: bounds.width)
    }

    /// Clusters glyphs into lines by vertical position; handles two-column charts.
    static func group(_ glyphs: [(PlacedGlyph, CGRect)], pageWidth: CGFloat) -> [PlacedLine] {
        guard !glyphs.isEmpty else { return [] }
        let heights = glyphs.map(\.1.height).sorted()
        let medianH = heights[heights.count / 2]
        let sorted = glyphs.sorted { $0.1.midY > $1.1.midY }   // PDF origin is bottom-left: top line first
        var rows: [[(PlacedGlyph, CGRect)]] = []
        var rowY: [CGFloat] = []
        for g in sorted {
            if let last = rowY.last, abs(last - g.1.midY) < medianH * 0.45 {
                rows[rows.count - 1].append(g)
            } else {
                rows.append([g]); rowY.append(g.1.midY)
            }
        }

        // Find a vertical gutter (two-column SongSelect / PCO layouts).
        let bins = 120
        var coverage = [Int](repeating: 0, count: bins)
        for row in rows {
            var seen = Set<Int>()
            for (g, _) in row {
                let a = Int(max(0, min(CGFloat(bins - 1), g.x / pageWidth * CGFloat(bins))))
                let b = Int(max(0, min(CGFloat(bins - 1), (g.x + g.width) / pageWidth * CGFloat(bins))))
                for i in a...max(a, b) { seen.insert(i) }
            }
            seen.forEach { coverage[$0] += 1 }
        }
        let limit = max(1, rows.count / 20)
        var gutter: CGFloat?
        var run = 0, bestRun = 0, bestEnd = 0
        for i in Int(Double(bins) * 0.3)..<Int(Double(bins) * 0.7) {
            if coverage[i] <= limit { run += 1; if run > bestRun { bestRun = run; bestEnd = i } } else { run = 0 }
        }
        // Only treat it as two columns if both sides actually carry text.
        if bestRun >= 3 {
            let mid = CGFloat(bestEnd - bestRun / 2) / CGFloat(bins) * pageWidth
            let left = glyphs.filter { $0.0.x < mid }.count, right = glyphs.count - left
            if left > glyphs.count / 5 && right > glyphs.count / 5 { gutter = mid }
        }

        func makeLine(_ row: [(PlacedGlyph, CGRect)]) -> PlacedLine {
            let s = row.sorted { $0.0.x < $1.0.x }
            let y = s.map(\.1.midY).reduce(0, +) / CGFloat(s.count)
            return PlacedLine(y: y, glyphs: s.map(\.0), height: medianH)
        }
        guard let gutter else { return rows.map(makeLine) }
        let leftCol = rows.compactMap { r -> PlacedLine? in
            let part = r.filter { $0.0.x < gutter }
            return part.isEmpty ? nil : makeLine(part)
        }
        let rightCol = rows.compactMap { r -> PlacedLine? in
            let part = r.filter { $0.0.x >= gutter }
            return part.isEmpty ? nil : makeLine(part)
        }
        return leftCol + rightCol
    }

    // MARK: Parsing

    private static let metaWords = ["www.", ".com/", "ccli", "tempo", "bpm", "time -", "time:", "©", "copyright", "words and music", "music by",
                                    "words by", "for use solely", "license", "page ", "capo", "time signature", "arranged by"]

    static func detectKey(_ s: String) -> String? {
        guard let r = s.range(of: #"(?i)\bkey(?:\s+of)?\s*[:\-–]?\s*([A-G][#b♯♭]?m?)(?![a-z])"#, options: .regularExpression) else { return nil }
        let match = String(s[r])
        guard let k = match.range(of: #"[A-G][#b♯♭]?m?$"#, options: .regularExpression) else { return nil }
        return String(match[k]).replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
    }

    static func sectionName(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"(?i)\s*[\(\[]?\s*(\d\s*x|x\s*\d)\s*[\)\]]?\s*$"#, with: "", options: .regularExpression)
        return LyricParser.heading(cleaned)
    }

    static func isRoadmap(_ line: String) -> Bool {
        let parts = line.components(separatedBy: CharacterSet(charactersIn: ">→")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.count >= 2 && parts.allSatisfy { sectionName($0) != nil }
    }

    /// Picks the character a chord belongs to. Chords sit at (or just right of) the start of a syllable;
    /// one floating in the gap between words belongs to whichever word start is nearer.
    static func place(chordX: CGFloat, string: String, xs: [CGFloat], widths: [CGFloat], height: CGFloat) -> Int {
        let words = ChordMatcher.wordSpans(string)
        guard !words.isEmpty, !xs.isEmpty else { return 0 }
        let snap = height * 0.5
        func end(_ w: (start: Int, length: Int, norm: String)) -> CGFloat {
            let lastI = w.start + w.length - 1
            return xs[lastI] + (widths[safe: lastI] ?? height * 0.55)
        }
        for w in words {
            let sx = xs[w.start]
            let lastI = w.start + w.length - 1
            let ex = end(w)
            if chordX >= sx - snap * 0.4, chordX < ex - height * 0.15 {
                if chordX - sx < snap { return w.start }
                // Mid-word (a held note changing chord): the letter under the chord.
                let i = xs.lastIndex(where: { $0 <= chordX + height * 0.15 }) ?? w.start
                return min(max(i, w.start), lastI)
            }
        }
        let prev = words.last { xs[$0.start] <= chordX }
        let next = words.first { xs[$0.start] > chordX }
        switch (prev, next) {
        case let (p?, n?):
            return chordX - xs[p.start] < xs[n.start] - chordX ? p.start : n.start
        case let (nil, n?):
            return n.start
        case let (p?, nil):
            // Past the last word: a chord change while the note is held.
            return chordX >= end(p) - height * 0.1 ? string.count : p.start
        default:
            return 0
        }
    }

    /// "be - lieve" → "believe", moving chords with the text (a chord on the dash goes to the next syllable).
    static func joinSyllables(_ text: String, _ chords: [(index: Int, chord: String)]) -> (text: String, chords: [(index: Int, chord: String)]) {
        var chars = Array(text)
        var cs = chords
        var i = 1
        while i + 2 < chars.count {
            if chars[i] == " ", chars[i + 1] == "-", i + 2 < chars.count, chars[i + 2] == " ",
               chars[i - 1].isLetter, i + 3 < chars.count, chars[i + 3].isLetter {
                chars.removeSubrange(i...(i + 2))
                cs = cs.map { c in
                    if c.index < i { return c }
                    if c.index < i + 3 { return (index: i, chord: c.chord) }
                    return (index: c.index - 3, chord: c.chord)
                }
            } else {
                i += 1
            }
        }
        return (String(chars), cs)
    }

    static func isChordLine(_ tokens: [(text: String, x: CGFloat)]) -> Bool {
        let real = tokens.filter { !["|", "/", "-", "%"].contains($0.text) }
        guard !real.isEmpty else { return false }
        return real.allSatisfy { Chord.isChordToken($0.text) } && real.contains { Chord.isRealChord($0.text) }
    }

    static func parse(_ lines: [PlacedLine], fallbackTitle: String) -> ChordChart {
        var chart = ChordChart()
        var section = ChordChart.Section(name: "", lines: [])
        var pendingChords: [(text: String, x: CGFloat)]? = nil
        var titleCandidates: [String] = []
        var seenContent = false
        var inFooter = false
        var headerLines: Set<String> {
            Set(titleCandidates)
        }

        func flushSection() {
            if !section.lines.isEmpty { chart.sections.append(section) }
            section = ChordChart.Section(name: "", lines: [])
        }
        func flushPendingAsInstrumental() {
            if let p = pendingChords {
                section.lines.append(.init(lyric: "", chords: p.enumerated().compactMap { i, t in
                    Chord.isRealChord(t.text) ? (index: i * 4, chord: t.text) : nil
                }))
                pendingChords = nil
            }
        }

        for line in lines {
            let (string, xs, widths, tokens) = line.layout()
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if chart.key == nil, let k = detectKey(trimmed) { chart.key = k }
            let lower = trimmed.lowercased()
            if lower.contains("key") && detectKey(trimmed) != nil && !isChordLine(tokens) { continue }
            // Copyright blocks run several lines; ignore everything after one until the next section starts.
            if lower.contains("©") || lower.contains("ccli song") || lower.contains("unauthorized") { inFooter = true; continue }
            if metaWords.contains(where: { lower.contains($0) }) { continue }
            // Repeated page headers (title, artist, website) on page 2+.
            if seenContent, headerLines.contains(trimmed) { continue }
            // Roadmap: "Intro > Verse 1 > Chorus > …"
            if isRoadmap(trimmed) {
                chart.roadmap += trimmed.components(separatedBy: CharacterSet(charactersIn: ">→|,"))
                    .compactMap { sectionName($0) }
                continue
            }

            if let name = sectionName(trimmed) {
                inFooter = false
                flushPendingAsInstrumental()
                flushSection()
                section.name = name
                seenContent = true
                continue
            }
            // A section label followed by chords on the same line ("Intro | G D Em C").
            if let first = tokens.first, sectionName(first.text) != nil, isChordLine(Array(tokens.dropFirst())) {
                flushPendingAsInstrumental()
                flushSection()
                section.name = sectionName(first.text)!
                pendingChords = Array(tokens.dropFirst())
                flushPendingAsInstrumental()
                seenContent = true
                continue
            }
            if inFooter { continue }
            if isChordLine(tokens) {
                flushPendingAsInstrumental()
                pendingChords = tokens.filter { Chord.isRealChord($0.text) }
                seenContent = true
                continue
            }
            // Lyric line
            if !seenContent { titleCandidates.append(trimmed); continue }
            var chords: [(index: Int, chord: String)] = []
            if let p = pendingChords {
                for t in p {
                    chords.append((index: place(chordX: t.x, string: string, xs: xs, widths: widths, height: line.height), chord: t.text))
                }
                pendingChords = nil
            }
            let joined = joinSyllables(string, chords)
            if section.name.isEmpty { section.name = "Verse 1" }
            section.lines.append(.init(lyric: joined.text, chords: joined.chords))
        }
        flushPendingAsInstrumental()
        flushSection()

        chart.title = titleCandidates.first ?? fallbackTitle
        if chart.key == nil { chart.key = Nashville.guessKey(chart.allChords) }
        return chart
    }

    static func parseChordPro(_ text: String, fallbackTitle: String) -> ChordChart {
        var chart = ChordChart()
        var section = ChordChart.Section(name: "Verse 1", lines: [])
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // ChordPro directives: {title: …}, {key: G}, {start_of_chorus}, {comment: Verse 2}
            if line.hasPrefix("{"), line.hasSuffix("}") {
                let body = line.dropFirst().dropLast()
                let parts = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let directive = parts[0].lowercased()
                let value = parts.count > 1 ? parts[1] : ""
                switch directive {
                case "title", "t": chart.title = value
                case "key": chart.key = value
                case "start_of_chorus", "soc":
                    if !section.lines.isEmpty { chart.sections.append(section) }
                    section = .init(name: value.isEmpty ? "Chorus" : value, lines: [])
                case "start_of_verse", "sov", "start_of_bridge", "sob":
                    if !section.lines.isEmpty { chart.sections.append(section) }
                    section = .init(name: value.isEmpty ? (directive.contains("b") && directive != "sov" ? "Bridge" : "Verse") : value, lines: [])
                case "comment", "c", "ci":
                    if let name = sectionName(value) {
                        if !section.lines.isEmpty { chart.sections.append(section) }
                        section = .init(name: name, lines: [])
                    }
                default: break
                }
                continue
            }
            if let name = sectionName(line) {
                if !section.lines.isEmpty { chart.sections.append(section) }
                section = .init(name: name, lines: [])
                continue
            }
            if chart.key == nil, let k = detectKey(line) { chart.key = k; continue }
            let (lyric, placements) = ChordPro.decode(line)
            section.lines.append(.init(lyric: lyric, chords: placements.map { (index: $0.index, chord: $0.chord) }))
        }
        if !section.lines.isEmpty { chart.sections.append(section) }
        if chart.title.isEmpty { chart.title = fallbackTitle }
        if chart.key == nil { chart.key = Nashville.guessKey(chart.allChords) }
        return chart
    }
}
