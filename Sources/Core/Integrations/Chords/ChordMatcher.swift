import Foundation

/// Puts a chart's chords onto a presentation's slides by matching lyric lines.
enum ChordMatcher {
    struct Report: Hashable {
        var matchedLines = 0
        var totalLines = 0
        var unmatchedChartLines: [String] = []
        var key: String?
        var summary: String {
            "Placed chords on \(matchedLines) of \(totalLines) lyric lines" + (key.map { " · key of \($0)" } ?? "")
                + (unmatchedChartLines.isEmpty ? "" : " · \(unmatchedChartLines.count) chart lines didn't match")
        }
    }

    static func words(_ s: String) -> [String] {
        LyricFollower.tokens(s)
    }

    /// Word spans (start offset, normalized word) in the original string.
    static func wordSpans(_ s: String) -> [(start: Int, length: Int, norm: String)] {
        var out: [(Int, Int, String)] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i].isLetter || chars[i].isNumber || chars[i] == "'" || chars[i] == "’" {
                let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "'" || chars[i] == "’" { i += 1 }
                let w = String(chars[start..<i]).lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
                out.append((start, i - start, w))
            } else { i += 1 }
        }
        return out
    }

    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let l = LyricFollower.lcs(a, b).length
        return Double(l) / Double(max(a.count, b.count))
    }

    /// Fuzzy LCS alignment returning matched word index pairs (a → b).
    static func align(_ a: [String], _ b: [String]) -> [Int: Int] {
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = LyricFollower.similar(a[i - 1], b[j - 1]) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var map: [Int: Int] = [:]
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if LyricFollower.similar(a[i - 1], b[j - 1]), dp[i][j] == dp[i - 1][j - 1] + 1 {
                map[i - 1] = j - 1; i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        return map
    }

    /// Moves chord offsets from the chart's wording of a line to the slide's wording of it.
    static func transfer(_ chords: [(index: Int, chord: String)], from chartLine: String, to slideLine: String) -> [(Int, String)] {
        if chartLine == slideLine { return chords.map { ($0.index, $0.chord) } }
        let a = wordSpans(chartLine), b = wordSpans(slideLine)
        // Real lyric lines are a dozen words. A pathological line would make the fuzzy alignment crawl on the main
        // thread, so past a sane size just place chords proportionally.
        if a.count > 60 || b.count > 60 {
            let ratio = Double(slideLine.count) / Double(max(1, chartLine.count))
            return chords.map { (min(slideLine.count, Int(Double($0.index) * ratio)), $0.chord) }
        }
        let map = align(a.map(\.norm), b.map(\.norm))
        let slideLen = slideLine.count
        return chords.map { c in
            // Which chart word is the chord over (or just before)?
            guard let k = a.lastIndex(where: { $0.start <= c.index }) else {
                return (0, c.chord)
            }
            let offset = c.index - a[k].start
            if let j = map[k] {
                return (b[j].start + min(offset, b[j].length), c.chord)
            }
            // Unaligned word: anchor on the nearest aligned word before it, else fall back to proportion.
            if let prev = (0..<k).reversed().first(where: { map[$0] != nil }), let pj = map[prev] {
                let delta = c.index - a[prev].start
                return (min(slideLen, b[pj].start + delta), c.chord)
            }
            let ratio = Double(c.index) / Double(max(1, chartLine.count))
            return (min(slideLen, Int(ratio * Double(slideLen))), c.chord)
        }
    }

    /// Applies a chart to a presentation. Songs with no slides yet are built from the chart's lyrics.
    @discardableResult
    static func apply(_ chart: ChordChart, to p: inout Presentation, maxLines: Int) -> Report {
        var report = Report(key: chart.key)
        if p.groups.allSatisfy({ $0.slides.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) {
            let text = chart.sections.map { s in
                "[\(s.name)]\n" + s.lines.map(\.lyric).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            LyricParser.apply(text: text, to: &p, maxLines: maxLines)
            if p.name.isEmpty || p.name.hasPrefix("New ") { p.name = chart.title }
        }
        if p.key == nil || p.key?.isEmpty == true { p.key = chart.key }

        let chartLines = chart.lyricLines.map { (section: $0.section, line: $0.line, words: words($0.line.lyric)) }
        var used = Set<Int>()

        for gi in p.groups.indices {
            let groupKey = LyricParser.normalizeSectionKey(p.groups[gi].name)
            var lastMatch: Int? = nil
            for si in p.groups[gi].slides.indices {
                let lines = p.groups[gi].slides[si].text.components(separatedBy: "\n")
                var placements: [ChordPlacement] = []
                for (li, line) in lines.enumerated() {
                    let w = words(line)
                    guard !w.isEmpty else { continue }
                    report.totalLines += 1
                    var best: (score: Double, idx: Int)? = nil
                    for (ci, cl) in chartLines.enumerated() {
                        var score = similarity(w, cl.words)
                        guard score > 0.4 else { continue }
                        // Prefer the same section, and the line right after the last one we matched.
                        let sectionKey = LyricParser.normalizeSectionKey(cl.section)
                        if sectionKey == groupKey { score += 0.15 }
                        else if sectionKey.prefix(4) == groupKey.prefix(4) { score += 0.05 }
                        if let lm = lastMatch, ci == lm + 1 { score += 0.1 }
                        if used.contains(ci) { score -= 0.02 }
                        if best == nil || score > best!.score { best = (score, ci) }
                    }
                    guard let b = best, b.score >= 0.6 else { continue }
                    lastMatch = b.idx
                    used.insert(b.idx)
                    report.matchedLines += 1
                    let cl = chartLines[b.idx].line
                    for (index, chord) in transfer(cl.chords, from: cl.lyric, to: line) {
                        placements.append(ChordPlacement(line: li, index: index, chord: chord))
                    }
                }
                p.groups[gi].slides[si].chords = placements.isEmpty ? nil : placements
            }
        }
        report.unmatchedChartLines = chartLines.enumerated().filter { !used.contains($0.offset) }.map(\.element.line.lyric)
        return report
    }
}

/// Splits a line into (chord, text) segments for rendering chords above lyrics.
enum ChordLayout {
    struct Segment: Hashable {
        var chord: String?
        var text: String
    }

    static func segments(line: String, chords: [ChordPlacement]) -> [Segment] {
        let sorted = chords.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
        guard !sorted.isEmpty else { return [Segment(chord: nil, text: line)] }
        let chars = Array(line)
        var out: [Segment] = []
        if sorted[0].index > 0 { out.append(Segment(chord: nil, text: String(chars[0..<min(sorted[0].index, chars.count)]))) }
        for (i, c) in sorted.enumerated() {
            let start = min(c.index, chars.count)
            let end = i + 1 < sorted.count ? min(sorted[i + 1].index, chars.count) : chars.count
            var text = start < end ? String(chars[start..<end]) : ""
            // Two chords on one syllable (or past the end of the words) need room to breathe.
            if text.isEmpty { text = "  " }
            out.append(Segment(chord: c.chord, text: text))
        }
        return out
    }

    static func label(_ chord: String, key: String?, style: ChordStyle) -> String {
        guard let key, let k = MusicKey(key) else { return chord }
        // Charts can be written in numbers ("6m") or letters ("Em"); show whichever the style asks for.
        let isNumber = Chord.isNumberChord(chord)
        let number = isNumber ? chord : Nashville.number(for: chord, key: k)
        let letter = isNumber ? (Nashville.letter(for: chord, key: k) ?? chord) : chord
        switch style {
        case .letters: return letter
        case .nashville: return number
        case .both: return "\(number) \(letter)"
        }
    }
}
