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
        /// The chart's performance note for this section ("A little bigger", "Piano & Acoustic Guitar").
        var note: String = ""
        /// False for a heading with nothing under it, which means "sing that section again here".
        var hasContent: Bool { lines.contains { !$0.lyric.trimmingCharacters(in: .whitespaces).isEmpty || !$0.chords.isEmpty } }
    }

    var title: String = ""
    var artist: String = ""
    var ccli: String = ""
    var key: String?
    /// The song order printed at the top of the chart: MultiTracks' circled roadmap, or "Intro > Verse 1 > …".
    var roadmap: [String] = []
    /// Every section in the order it's printed. A heading with nothing under it, or a jump line partway through
    /// ("Pre-Chorus 1 > Chorus 1"), appears as an empty section: that section is sung again there.
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
    /// Font size when the PDF says (0 for OCR and plain text).
    var size: CGFloat = 0
    /// Grey text: arrangement notes like "Piano & Acoustic Guitar", never lyrics.
    var isNote = false
    /// Printed smaller and tucked against the glyph before it: a chord extension (6m⁷, 1sus⁴) or a repeat count (Rf²).
    var isSuper = false
}

struct PlacedLine {
    var y: CGFloat
    var glyphs: [PlacedGlyph]   // sorted by x, whitespace removed
    var height: CGFloat

    var isNote: Bool { !glyphs.isEmpty && glyphs.filter(\.isNote).count * 10 >= glyphs.count * 7 }

    /// Rebuilds the line as text, inserting a single space wherever glyphs are visibly apart,
    /// and returns each character's x so chords can be dropped onto the right letter.
    func text() -> (string: String, xs: [CGFloat], tokens: [(text: String, x: CGFloat)]) {
        let t = layout()
        return (t.string, t.xs, t.tokens)
    }

    /// Like `text()`, plus each character's width so word ends are exact. A chord's superscript stays part of
    /// the chord ("6m⁷" → "6m7", "5⁶" → "5(6)", "1sus⁴" → "1sus4").
    func layout() -> (string: String, xs: [CGFloat], widths: [CGFloat], tokens: [(text: String, x: CGFloat)]) {
        let r = scan()
        return (r.string, r.xs, r.widths, r.words.map { (ChordChartReader.chordText($0.segments), $0.x) })
    }

    /// Each word with its normal and superscript parts kept apart ("Rf" + "2" on a roadmap means Refrain twice).
    func parts() -> [(base: String, sup: String, x: CGFloat)] {
        scan().words.map { w in
            (w.segments.filter { !$0.sup }.map(\.text).joined(), w.segments.filter(\.sup).map(\.text).joined(), w.x)
        }
    }

    private func scan() -> (string: String, xs: [CGFloat], widths: [CGFloat], words: [(segments: [(text: String, sup: Bool)], x: CGFloat)]) {
        var s = ""
        var xs: [CGFloat] = []
        var ws: [CGFloat] = []
        var words: [([(text: String, sup: Bool)], CGFloat)] = []
        var segs: [(text: String, sup: Bool)] = []
        var currentX: CGFloat = 0
        let gapThreshold = max(1, height * 0.2)
        for (i, g) in glyphs.enumerated() {
            if i > 0 {
                let prev = glyphs[i - 1]
                let gap = g.x - (prev.x + prev.width)
                if gap >= gapThreshold, !g.isSuper {   // a superscript always belongs to what's before it
                    s.append(" "); xs.append(prev.x + prev.width); ws.append(gap)
                    if !segs.isEmpty { words.append((segs, currentX)); segs = [] }
                }
            }
            if segs.isEmpty { currentX = g.x }
            if let last = segs.last, last.sup == g.isSuper { segs[segs.count - 1].text.append(g.char) }
            else { segs.append((String(g.char), g.isSuper)) }
            s.append(g.char); xs.append(g.x); ws.append(g.width)
        }
        if !segs.isEmpty { words.append((segs, currentX)) }
        return (s, xs, ws, words)
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

    /// A quick look at a PDF's text layer (no OCR, so a big slide deck isn't slowed down): does it have several
    /// lines made only of chords or Nashville numbers? That's a chord chart rather than slides.
    static func looksLikeChart(_ doc: PDFDocument) -> Bool {
        var chordLines = 0
        for i in 0..<min(doc.pageCount, 4) {
            guard let page = doc.page(at: i) else { continue }
            chordLines += textLines(page).filter { isChordLine($0.layout().tokens) }.count
            if chordLines >= 3 { return true }
        }
        return false
    }

    static func looksLikeChart(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) else { return false }
        return looksLikeChart(doc)
    }

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
        // Font sizes and colours come from the page's attributed text, read once. Its indices drift from the glyph
        // indices after line breaks, so follow the drift instead of asking PDFKit about every character.
        let attr = page.attributedString
        let units = attr.map { Array($0.string.utf16) } ?? []
        var drift = 0
        var glyphs: [(PlacedGlyph, CGRect)] = []
        var last: (Character, CGRect)?
        for i in 0..<count {
            guard let sel = page.selection(for: NSRange(location: i, length: 1)),
                  let str = sel.string, str.count == 1, let c = str.first,
                  !c.isWhitespace, !c.isNewline else { continue }
            let r = sel.bounds(for: page)
            guard r.width > 0, r.height > 0 else { continue }
            var size: CGFloat = 0
            var note = false
            if let attr, str.utf16.count == 1, let u = str.utf16.first {
                for d in [0, 1, -1, 2, -2, 3, -3, 4, -4] {
                    let j = i + drift + d
                    guard j >= 0, j < units.count, units[j] == u else { continue }
                    drift += d
                    if let f = attr.attribute(.font, at: j, effectiveRange: nil) as? NSFont { size = f.pointSize }
                    if let col = attr.attribute(.foregroundColor, at: j, effectiveRange: nil) as? NSColor { note = isNoteColor(col) }
                    break
                }
            }
            // Line breaks can echo the previous glyph; skip exact repeats.
            if let l = last, l.0 == c, abs(l.1.minX - r.minX) < 0.5, abs(l.1.minY - r.minY) < 0.5 { continue }
            last = (c, r)
            glyphs.append((PlacedGlyph(char: c, x: r.minX, width: r.width, size: size, isNote: note), r))
        }
        return group(glyphs, pageWidth: page.bounds(for: .mediaBox).width)
    }

    /// Mid-grey text is a performance note ("A little bigger"); lyrics and chords are black (or white, or coloured).
    static func isNoteColor(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        return max(r, g, b) - min(r, g, b) < 0.1 && lum > 0.3 && lum < 0.88
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
        let sizes = glyphs.map(\.0.size).filter { $0 > 0 }.sorted()
        let bodySize = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
        typealias Row = [Int]   // indices into `glyphs`
        func midY(_ r: Row) -> CGFloat { r.map { glyphs[$0].1.midY }.reduce(0, +) / CGFloat(max(1, r.count)) }

        /// Rows by vertical position, top first (PDF origin is bottom-left).
        func cluster(_ ids: [Int]) -> [Row] {
            var rows: [Row] = []
            var rowY: [CGFloat] = []
            for i in ids.sorted(by: { glyphs[$0].1.midY > glyphs[$1].1.midY }) {
                let y = glyphs[i].1.midY
                if let last = rowY.last, abs(last - y) < medianH * 0.45 {
                    rows[rows.count - 1].append(i)
                } else {
                    rows.append([i]); rowY.append(y)
                }
            }
            // Superscripts raised onto a baseline of their own (6m⁷, 1²/3, or MultiTracks' repeat counts over the
            // roadmap) join the row next to them, where each one sits against the glyph it belongs to.
            guard bodySize > 0 else { return rows }
            var k = 0
            while k < rows.count {
                let r = rows[k]
                let small = r.count <= 8 && r.allSatisfy { glyphs[$0].0.size > 0 && glyphs[$0].0.size < bodySize * 0.82 }
                let target = !small ? nil : [k + 1, k - 1].first { j in
                    rows.indices.contains(j) && abs(midY(rows[j]) - midY(r)) < medianH * 1.3
                        && r.allSatisfy { g in rows[j].contains { abs(glyphs[g].1.minX - glyphs[$0].1.maxX) < 4 } }
                }
                if let j = target {
                    rows[j] += r
                    rows.remove(at: k)
                    if j < k { k -= 1 }
                } else {
                    k += 1
                }
            }
            return rows
        }

        func makeLine(_ row: Row) -> PlacedLine {
            let s = row.sorted { glyphs[$0].0.x < glyphs[$1].0.x }
            let y = midY(s)
            var line = s.map { glyphs[$0].0 }
            // A smaller glyph tucked against a full-size one is its superscript: 6m⁷, 5⁶, 1sus⁴, Rf².
            let top = line.map(\.size).max() ?? 0
            if top > 0 {
                for k in line.indices.dropFirst() {
                    let g = line[k], prev = line[k - 1]
                    guard g.size > 0, g.size < top * 0.82, g.x - (prev.x + prev.width) < max(3, medianH * 0.35) else { continue }
                    if prev.isSuper || prev.size >= top * 0.82 { line[k].isSuper = true }
                }
            }
            // Word gaps scale with this line's own type size (an 11-point artist line, a 23-point title).
            let own = s.map { glyphs[$0].1.height }.sorted()
            return PlacedLine(y: y, glyphs: line, height: bodySize > 0 ? own[own.count / 2] : medianH)
        }

        let all = Array(glyphs.indices)
        let rows = cluster(all)

        // Find a vertical gutter (two-column SongSelect / PCO / MultiTracks / PraiseCharts layouts).
        let bins = 120
        var coverage = [Int](repeating: 0, count: bins)
        for row in rows {
            var seen = Set<Int>()
            for i in row {
                let g = glyphs[i].0
                let a = Int(max(0, min(CGFloat(bins - 1), g.x / pageWidth * CGFloat(bins))))
                let b = Int(max(0, min(CGFloat(bins - 1), (g.x + g.width) / pageWidth * CGFloat(bins))))
                for j in a...max(a, b) { seen.insert(j) }
            }
            seen.forEach { coverage[$0] += 1 }
        }
        let limit = max(1, rows.count / 20)
        var run = 0, bestRun = 0, bestEnd = 0
        for i in Int(Double(bins) * 0.3)..<Int(Double(bins) * 0.7) {
            if coverage[i] <= limit { run += 1; if run > bestRun { bestRun = run; bestEnd = i } } else { run = 0 }
        }
        // Only treat it as two columns if both sides actually carry text.
        guard bestRun >= 3 else { return rows.map(makeLine) }
        let gutter = CGFloat(bestEnd - bestRun / 2) / CGFloat(bins) * pageWidth
        let leftCount = glyphs.filter { $0.0.x < gutter }.count
        guard leftCount > glyphs.count / 5, glyphs.count - leftCount > glyphs.count / 5 else { return rows.map(makeLine) }

        // A row runs across the gutter (the title, MultiTracks' roadmap, a footer) when its text continues over it
        // rather than stopping on one side and starting again on the other.
        func crosses(_ r: Row) -> Bool {
            let left = r.filter { glyphs[$0].1.midX < gutter }.map { glyphs[$0].1.maxX }.max()
            let right = r.filter { glyphs[$0].1.midX >= gutter }.map { glyphs[$0].1.minX }.min()
            guard let left, let right else { return false }
            return right - left < pageWidth * 0.05
        }
        /// A whole-width row with a wide empty stretch is separate things ("Title ……… Page: 1/3").
        func pieces(_ r: Row) -> [Row] {
            let s = r.sorted { glyphs[$0].1.minX < glyphs[$1].1.minX }
            var out: [Row] = [[]]
            for i in s {
                if let last = out[out.count - 1].last, glyphs[i].1.minX - glyphs[last].1.maxX > pageWidth * 0.15 { out.append([]) }
                out[out.count - 1].append(i)
            }
            return out.filter { !$0.isEmpty }
        }

        let whole = rows.filter(crosses)
        let inWhole = Set(whole.flatMap { $0 })
        let rest = all.filter { !inWhole.contains($0) }
        let leftRows = cluster(rest.filter { glyphs[$0].0.x < gutter })
        let rightRows = cluster(rest.filter { glyphs[$0].0.x >= gutter })
        let columnYs = (leftRows + rightRows).map(midY)
        let top = columnYs.max() ?? .infinity, bottom = columnYs.min() ?? -.infinity
        var head: [Row] = [], foot: [Row] = [], middle: [Row] = []
        for r in whole {
            let y = midY(r)
            if y > top { head += pieces(r) } else if y < bottom { foot += pieces(r) } else { middle += pieces(r) }
        }
        // Whole-width rows partway down (rare) are read with the left column, in position.
        let leftFlow = (leftRows + middle).sorted { midY($0) > midY($1) }
        return (head + leftFlow + rightRows + foot).map(makeLine)
    }

    // MARK: Parsing

    private static let metaWords = ["www.", ".com/", "ccli", "tempo", "bpm", "time -", "time:", "©", "copyright", "words and music", "music by",
                                    "words by", "for use solely", "license", "page ", "capo", "time signature", "arranged by",
                                    "writers:", "written by", "multitracks", "praisecharts", "a product of", "mtid", "key:"]

    static func isPageNumber(_ lower: String) -> Bool {
        lower.range(of: #"^page\s*:?\s*\d+\s*(/|of)\s*\d+$"#, options: .regularExpression) != nil
    }

    static func detectCCLI(_ s: String) -> String? {
        guard let r = s.range(of: #"(?i)ccli\s*(?:song)?\s*(?:no\.?|#|number)?\s*:?\s*(\d{4,8})"#, options: .regularExpression) else { return nil }
        return String(s[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter { $0.count >= 4 }.first
    }

    // MARK: Section badges and roadmaps (MultiTracks)

    /// A circled section badge: "I", "C1", "Rf", "Tg", "PC2".
    static func isBadge(_ s: String) -> Bool {
        s.range(of: #"^[A-Z][A-Za-z]{0,2}\d{0,2}$"#, options: .regularExpression) != nil
    }

    static let abbreviations: [String: String] = [
        "i": "Intro", "in": "Intro", "v": "Verse", "c": "Chorus", "ch": "Chorus", "pc": "Pre-Chorus", "b": "Bridge", "br": "Bridge",
        "t": "Tag", "tg": "Tag", "ta": "Turnaround", "rf": "Refrain", "r": "Refrain", "vp": "Vamp", "it": "Interlude", "o": "Outro",
        "e": "Ending", "ins": "Instrumental", "bd": "Breakdown", "poc": "Post-Chorus", "h": "Hook",
    ]

    static func expand(badge: String) -> String? {
        let letters = badge.prefix { $0.isLetter }, digits = badge.drop { $0.isLetter }
        guard let name = abbreviations[letters.lowercased()] else { return nil }
        return digits.isEmpty ? name : "\(name) \(digits)"
    }

    /// The chart's own badges, from headings like "C1 CHORUS 1" and "Ta TURNAROUND".
    static func badgeNames(_ lines: [PlacedLine]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            let t = line.layout().tokens.map(\.text)
            if t.count >= 2, isBadge(t[0]), let name = sectionName(t.dropFirst().joined(separator: " ")) { out[t[0]] = name }
        }
        return out
    }

    /// MultiTracks prints the song order as a row of circled badges, with a small number for repeats (Rf² = Refrain twice).
    static func badgeRoadmap(_ line: PlacedLine, badges: [String: String]) -> [String]? {
        guard !badges.isEmpty else { return nil }
        var items: [(base: String, times: Int)] = []
        for part in line.parts() {
            if part.base.allSatisfy(\.isNumber), let n = Int(part.base), !items.isEmpty {
                items[items.count - 1].times = n   // a repeat count that didn't tuck in as a superscript
                continue
            }
            items.append((part.base, Int(part.sup) ?? 1))
        }
        guard items.count >= 3, items.allSatisfy({ isBadge($0.base) }),
              items.filter({ badges[$0.base] != nil }).count * 10 >= items.count * 7 else { return nil }
        return items.flatMap { item in
            Array(repeating: badges[item.base] ?? expand(badge: item.base) ?? item.base, count: max(1, min(8, item.times)))
        }
    }

    /// A chord written with a superscript: extensions are appended (6m⁷ → 6m7, 1sus⁴ → 1sus4, 1maj⁷/3 → 1maj7/3),
    /// and a bare added note on a number chord is bracketed the way charts print it in text (5⁶ → 5(6), 4²/6 → 4(2)/6).
    static func chordText(_ segments: [(text: String, sup: Bool)]) -> String {
        var out = ""
        for (text, sup) in segments {
            let numberChord = out.first.map { $0.isNumber || $0 == "b" || $0 == "#" } ?? false
            if sup, numberChord, ["2", "4", "6"].contains(text) { out += "(\(text))" } else { out += text }
        }
        return out
    }

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

    private static let suffixes: Set<String> = ["ing", "ings", "ed", "es", "s", "ns", "ly", "er", "ers", "est", "en", "y",
                                                "tion", "tions", "sion", "ness", "ment", "ful", "less", "able", "ible", "ous", "ance", "ence"]

    /// Rejoins lyric words that a chart split to make room for chords, moving the chords with the text:
    /// "be - lieve", "sha- ken", "f - -a- - il" (a held word stretched out), and "generatio ns" / "go ing", where a
    /// chord forced a gap partway through a word. Two real words are never glued into a non-word.
    static func joinSyllables(_ text: String, _ chords: [(index: Int, chord: String)],
                              isWord: (String) -> Bool = SpellCheck.isWord) -> (text: String, chords: [(index: Int, chord: String)]) {
        let chars = Array(text)
        var tokens: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            if chars[i] == " " { i += 1; continue }
            let s = i
            while i < chars.count, chars[i] != " " { i += 1 }
            tokens.append(s..<i)
        }
        guard tokens.count > 1 else { return (text, chords) }
        let dashes: Set<Character> = ["-", "–", "—"]
        func isDash(_ r: Range<Int>) -> Bool { chars[r].allSatisfy { dashes.contains($0) } }
        /// The token without hyphens at either end.
        func core(_ r: Range<Int>) -> Range<Int> {
            var a = r.lowerBound, b = r.upperBound
            while a < b, dashes.contains(chars[a]) { a += 1 }
            while b > a, dashes.contains(chars[b - 1]) { b -= 1 }
            return a..<b
        }
        func bare(_ s: String) -> String { s.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }

        var keep = [Bool](repeating: true, count: chars.count)
        guard let first = tokens.firstIndex(where: { !isDash($0) }) else { return (text, chords) }
        var word = String(chars[core(tokens[first])])          // the word built so far
        var wordEnd = core(tokens[first]).upperBound            // where its letters end in `chars`
        var openHyphen = chars[tokens[first].upperBound - 1] == "-"
        var dashBetween = false
        for t in tokens[(first + 1)...] {
            if isDash(t) { dashBetween = true; continue }
            let c = core(t)
            let piece = String(chars[c])
            let hyphenated = dashBetween || openHyphen || dashes.contains(chars[t.lowerBound])
            var join = false
            if let l = word.last, let r = piece.first, l.isLetter, r.isLetter {
                let left = bare(word), right = bare(piece)
                if hyphenated {
                    join = !(isWord(left) && isWord(right) && !isWord(left + right))
                } else if r.isLowercase {
                    // An ending left on its own ("go ing", "generation s") is a fragment even if a dictionary knows it.
                    let fragment = !isWord(right) || suffixes.contains(right.lowercased())
                    join = isWord(left + right) && (!isWord(left) || fragment)
                }
            }
            if join {
                for k in wordEnd..<c.lowerBound { keep[k] = false }
                word += piece
            } else {
                word = piece
            }
            wordEnd = c.upperBound
            openHyphen = chars[t.upperBound - 1] == "-"
            dashBetween = false
        }
        guard keep.contains(false) else { return (text, chords) }
        // Old index → new index; a chord on a removed character moves to the next one that's kept.
        var newIndex = [Int](repeating: 0, count: chars.count + 1)
        var n = 0
        for k in 0..<chars.count { newIndex[k] = n; if keep[k] { n += 1 } }
        newIndex[chars.count] = n
        let out = String(chars.indices.filter { keep[$0] }.map { chars[$0] })
        return (out, chords.map { (index: newIndex[min(max(0, $0.index), chars.count)], chord: $0.chord) })
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
        let badges = badgeNames(lines)

        func flushPendingAsInstrumental() {
            if let p = pendingChords {
                section.lines.append(.init(lyric: "", chords: p.enumerated().compactMap { i, t in
                    Chord.isRealChord(t.text) ? (index: i * 4, chord: t.text) : nil
                }))
                pendingChords = nil
            }
        }
        func flushSection() {
            // A named section with nothing under it is kept: it means "sing that one again here".
            if !section.name.isEmpty || !section.lines.isEmpty { chart.sections.append(section) }
            section = ChordChart.Section(name: "", lines: [])
        }
        func startSection(_ name: String) {
            flushPendingAsInstrumental()
            flushSection()
            section.name = name
            seenContent = true
            inFooter = false
        }

        for line in lines {
            let (string, xs, widths, tokens) = line.layout()
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()
            if chart.key == nil, let k = detectKey(trimmed) { chart.key = k }
            if chart.ccli.isEmpty, let n = detectCCLI(trimmed) { chart.ccli = n }
            if lower.contains("key") && detectKey(trimmed) != nil && !isChordLine(tokens) { continue }
            // Copyright blocks run several lines; ignore everything after one until the next section starts.
            if lower.contains("©") || lower.contains("ccli song") || lower.contains("unauthorized") { inFooter = true; continue }
            if isPageNumber(lower) || metaWords.contains(where: { lower.contains($0) }) { continue }
            // Grey text is a performance note for the section ("A little bigger"), or the artist under the title.
            if line.isNote {
                if seenContent { section.note += (section.note.isEmpty ? "" : " · ") + trimmed }
                else if chart.artist.isEmpty { chart.artist = trimmed }
                continue
            }
            // Repeated page headers (title, artist, website) on page 2+.
            if seenContent, titleCandidates.contains(trimmed) { continue }
            // MultiTracks' circled roadmap at the top: the whole song order.
            if !seenContent, let order = badgeRoadmap(line, badges: badges) { chart.roadmap += order; continue }
            // "Intro > Verse 1 > Chorus": at the top it's the song order; partway through (PraiseCharts' last line,
            // "Pre-Chorus 1 > Pre-Chorus 2 > Chorus 1 > Chorus 2") it means go back and sing those again here.
            if isRoadmap(trimmed) {
                let names = trimmed.components(separatedBy: CharacterSet(charactersIn: ">→|,")).compactMap { sectionName($0) }
                if seenContent {
                    flushPendingAsInstrumental()
                    flushSection()
                    chart.sections += names.map { ChordChart.Section(name: $0, lines: []) }
                } else {
                    chart.roadmap += names
                }
                continue
            }
            if let name = sectionName(trimmed) { startSection(name); continue }
            // MultiTracks headings carry their badge first: "C1 CHORUS 1", "Ta TURNAROUND".
            if tokens.count >= 2, isBadge(tokens[0].text), let name = sectionName(tokens.dropFirst().map(\.text).joined(separator: " ")) {
                startSection(name)
                continue
            }
            // A section label followed by chords on the same line ("Intro | G D Em C").
            if let first = tokens.first, let name = sectionName(first.text), isChordLine(Array(tokens.dropFirst())) {
                startSection(name)
                pendingChords = Array(tokens.dropFirst())
                flushPendingAsInstrumental()
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
            if section.name.isEmpty { section.name = chart.sections.isEmpty ? "Verse 1" : (chart.sections.last?.name ?? "Verse 1") }
            section.lines.append(.init(lyric: joined.text, chords: joined.chords))
        }
        flushPendingAsInstrumental()
        flushSection()

        chart.title = titleCandidates.first ?? fallbackTitle
        if chart.artist.isEmpty, titleCandidates.count > 1 { chart.artist = titleCandidates[1] }
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

/// Is this an English word? Used to put lyric words back together after a chart split them around chords.
enum SpellCheck {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func isWord(_ raw: String) -> Bool {
        let w = raw.lowercased()
        guard !w.isEmpty else { return false }
        // Single letters other than "a", "i" and "o" only ever appear as fragments ("f - a - il", "generation s").
        if w.count == 1 { return ["a", "i", "o"].contains(w) }
        lock.lock()
        if let hit = cache[w] { lock.unlock(); return hit }
        lock.unlock()
        let check = {
            NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        let ok = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        lock.lock(); cache[w] = ok; lock.unlock()
        return ok
    }
}
