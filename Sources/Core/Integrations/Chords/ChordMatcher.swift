import Foundation

/// Puts a chart's chords onto a presentation's slides by matching lyric lines.
enum ChordMatcher {
    struct Report: Hashable {
        var matchedLines = 0
        var totalLines = 0
        var unmatchedChartLines: [String] = []
        var key: String?
        /// How many sections the chart's song order set (0 = the order wasn't changed).
        var orderCount = 0
        var lockedFromSync = false
        var summary: String {
            "Placed chords on \(matchedLines) of \(totalLines) lyric lines" + (key.map { " · key of \($0)" } ?? "")
                + (orderCount > 0 ? " · song order: \(orderCount) sections" : "")
                + (lockedFromSync ? " · locked from Planning Center sync so it isn't overwritten" : "")
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
    /// `replaceLyrics` rebuilds the slides from the chart even if the song already has words; `applyOrder` sets the
    /// song order (verse, chorus, verse, chorus, bridge…) from the chart.
    @discardableResult
    static func apply(_ chart: ChordChart, to p: inout Presentation, maxLines: Int,
                      replaceLyrics: Bool = false, applyOrder: Bool = true) -> Report {
        var report = Report(key: chart.key)
        if p.key == nil || p.key?.isEmpty == true { p.key = chart.key }
        if p.author.isEmpty { p.author = chart.artist }
        if p.ccli.isEmpty { p.ccli = chart.ccli }
        let blank = p.groups.allSatisfy { $0.slides.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        if replaceLyrics || blank {
            let built = build(chart, maxLines: maxLines, reusing: p.groups)
            if !built.groups.isEmpty {
                p.groups = built.groups
                if p.name.isEmpty || p.name.hasPrefix("New ") { p.name = chart.title }
                let lyricLines = built.groups.reduce(0) { $0 + $1.slides.reduce(0) { $0 + $1.text.split(separator: "\n").count } }
                report.totalLines = lyricLines
                report.matchedLines = lyricLines
                let valid = Set(built.groups.map(\.id))
                if applyOrder, !built.order.isEmpty {
                    p.arrangement = built.order
                    report.orderCount = built.order.count
                    if p.pcoSongID != nil, !p.lockedFromSync { p.lockedFromSync = true; report.lockedFromSync = true }
                } else {
                    p.arrangement = p.arrangement.filter(valid.contains)
                }
                return report
            }
        }

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
        // A section printed several times only needs to match once.
        let matchedWords = Set(used.map { chartLines[$0].words })
        report.unmatchedChartLines = chartLines.enumerated()
            .filter { !used.contains($0.offset) && !matchedWords.contains($0.element.words) }.map(\.element.line.lyric)
        if applyOrder, let order = songOrder(of: chart, groups: p.groups), !order.isEmpty {
            p.arrangement = order
            report.orderCount = order.count
            // A Planning Center song would lose this order on its next sync.
            if p.pcoSongID != nil, !p.lockedFromSync { p.lockedFromSync = true; report.lockedFromSync = true }
        }
        return report
    }

    /// Builds the slides straight from a chart. Each section becomes a group, and a section sung again reuses its
    /// group, so the order can repeat it. The chords are already in place, and the section's note goes on its
    /// first slide. An instrumental section (intro, interlude) becomes one blank slide: nothing for the room, its
    /// chords for the band. Group IDs and slide settings are kept where a group of that name already exists.
    static func build(_ chart: ChordChart, maxLines: Int, reusing old: [SlideGroup] = []) -> (groups: [SlideGroup], order: [UUID]) {
        var groups: [SlideGroup] = []
        var sectionKey: [UUID: String] = [:]
        var signature: [UUID: [String]] = [:]
        var lastByKey: [String: UUID] = [:]
        var order: [UUID] = []
        let maxLines = max(1, maxLines)

        for sec in chart.sections {
            let name = sec.name.isEmpty ? "Verse 1" : sec.name
            let key = LyricParser.normalizeSectionKey(name)
            let lyric = sec.lines.filter { !$0.lyric.trimmingCharacters(in: .whitespaces).isEmpty }
            let sig = lyric.flatMap { words($0.lyric) }
            if !sec.hasContent {
                // A heading on its own: that section again. With nothing earlier to repeat (a vamp), a blank slide.
                if let id = lastByKey[key] ?? groups.first(where: { sectionKey[$0.id] == key })?.id {
                    order.append(id)
                    continue
                }
            } else if let same = groups.first(where: { g in
                sectionKey[g.id] == key && (sig.isEmpty ? signature[g.id]?.isEmpty == true : similarity(sig, signature[g.id] ?? []) >= 0.85)
            }) {
                order.append(same.id)
                lastByKey[key] = same.id
                continue
            }

            var groupName = name
            var n = 2
            while groups.contains(where: { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }) {
                groupName = name.last?.isNumber == true ? "\(name) (\(n))" : "\(name) \(n)"
                n += 1
            }
            let previous = old.first { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }
            let slideContent = slides(for: sec, maxLines: maxLines)
            let slides = slideContent.enumerated().map { i, content -> Slide in
                var s = previous?.slides[safe: i] ?? Slide()
                s.text = content.text
                s.chords = content.chords.isEmpty ? nil : content.chords
                if i == 0, !sec.note.isEmpty, s.notes.isEmpty { s.notes = sec.note }
                return s
            }
            let g = SlideGroup(id: previous?.id ?? UUID(), name: groupName,
                               color: previous?.color ?? SlideGroup.color(for: groupName), slides: slides)
            groups.append(g)
            sectionKey[g.id] = key
            signature[g.id] = sig
            lastByKey[key] = g.id
            order.append(g.id)
        }

        // A roadmap printed at the top that's longer than what the chart spells out (sections printed once) wins.
        if chart.roadmap.count > order.count {
            let fromRoadmap = LyricParser.arrangement(from: chart.roadmap, groups: groups)
            if fromRoadmap.count == chart.roadmap.count { order = fromRoadmap }
        }
        return (groups, order)
    }

    /// One section's lyric lines cut into slides, with each line's chords. Chords on a line with no words are kept:
    /// at the end of the line before (a held chord) or, at the start, on the first line.
    static func slides(for sec: ChordChart.Section, maxLines: Int) -> [(text: String, chords: [ChordPlacement])] {
        var lines: [(lyric: String, chords: [(Int, String)])] = []
        var leading: [(Int, String)] = []
        for l in sec.lines {
            if l.lyric.trimmingCharacters(in: .whitespaces).isEmpty {
                if lines.isEmpty { leading += l.chords.map { (0, $0.chord) } }
                else { let end = lines[lines.count - 1].lyric.count; lines[lines.count - 1].chords += l.chords.map { (end, $0.chord) } }
                continue
            }
            lines.append((l.lyric, leading + l.chords.map { ($0.index, $0.chord) }))
            leading = []
        }
        if lines.isEmpty {
            return [("", leading.map { ChordPlacement(line: 0, index: 0, chord: $0.1) })]
        }
        return stride(from: 0, to: lines.count, by: maxLines).map { start in
            let chunk = lines[start..<min(start + maxLines, lines.count)]
            let text = chunk.map(\.lyric).joined(separator: "\n")
            let chords = chunk.enumerated().flatMap { li, line in line.chords.map { ChordPlacement(line: li, index: $0.0, chord: $0.1) } }
            return (text, chords)
        }
    }

    /// The chart's song order as group IDs, for a song whose slides already exist: every section in the order it's
    /// printed (a heading with nothing under it is that section again), or the printed roadmap if that's longer.
    /// Nil if it can't be matched to the slides reliably.
    static func songOrder(of chart: ChordChart, groups: [SlideGroup]) -> [UUID]? {
        let keyed = groups.map { g in
            (id: g.id, key: LyricParser.normalizeSectionKey(g.name), sig: g.slides.flatMap { words($0.text) })
        }
        var order: [UUID] = []
        var lastByKey: [String: UUID] = [:]
        for sec in chart.sections where !sec.name.isEmpty {
            let key = LyricParser.normalizeSectionKey(sec.name)
            let sig = sec.lines.flatMap { words($0.lyric) }
            func sameName(_ k: String) -> Bool { k == key || k.hasPrefix(key) || key.hasPrefix(k) }
            var pick: UUID?
            if sig.isEmpty {
                pick = lastByKey[key] ?? keyed.first { $0.key == key }?.id ?? keyed.first { sameName($0.key) }?.id
            } else {
                let scored = keyed.map { ($0.id, similarity(sig, $0.sig) + (sameName($0.key) ? 0.1 : 0) + ($0.key == key ? 0.05 : 0)) }
                if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.7 { pick = best.0 }
                else { pick = keyed.first { $0.key == key }?.id }   // worded differently, but the name matches
            }
            if let pick { order.append(pick); lastByKey[key] = pick }
        }
        if chart.roadmap.count > order.count {
            let fromRoadmap = LyricParser.arrangement(from: chart.roadmap, groups: groups)
            if fromRoadmap.count == chart.roadmap.count { order = fromRoadmap }
        }
        guard order.count > 1 else { return nil }
        // Every section with words must still be somewhere in the show, or the order isn't trustworthy.
        let covered = Set(order)
        let missing = groups.contains { g in !covered.contains(g.id) && g.slides.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
        return missing ? nil : order
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
