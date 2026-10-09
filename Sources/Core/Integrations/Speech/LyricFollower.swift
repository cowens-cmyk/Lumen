import Foundation

/// Matches what's being sung against the arrangement and decides when to advance.
/// Pure logic (no audio) so it can be unit tested and tuned.
struct LyricFollower {
    struct Decision: Equatable {
        enum Kind: Equatable { case hold, advance(to: Int), jump(to: Int), offScript }
        var kind: Kind
        /// 0...1 — how sure we are about where the singer is.
        var confidence: Double
        /// Best-matching slide right now (may equal current).
        var bestIndex: Int?
    }

    private(set) var slideTokens: [[String]] = []
    private var stableCandidate: Int?
    private var stableCount = 0
    private(set) var lastMatchAt: Date = .distantPast
    var threshold: Double = 0.62
    var advanceAtEndOfSlide = true

    static let fillers: Set<String> = ["oh", "o", "ah", "ahh", "ooh", "oo", "yeah", "hey", "whoa", "woah", "uh", "um", "mm", "la", "na", "hmm"]

    init(slides: [String] = []) { load(slides) }

    mutating func load(_ slides: [String]) {
        slideTokens = slides.map(Self.tokens)
        stableCandidate = nil
        stableCount = 0
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillers.contains($0) }
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let la = a.count, lb = b.count
        guard min(la, lb) >= 4, abs(la - lb) <= 2 else { return false }
        // Recognizers often drop or add endings ("ransom"/"ransomed", "sing"/"singing").
        if min(la, lb) >= 5, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        return levenshtein(a, b) <= (min(la, lb) >= 7 ? 2 : 1)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }

    /// Fuzzy longest common subsequence length.
    static func lcs(_ x: [String], _ y: [String]) -> (length: Int, lastMatchInY: Int) {
        guard !x.isEmpty, !y.isEmpty else { return (0, -1) }
        var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 1...x.count {
            for j in 1...y.count {
                dp[i][j] = similar(x[i - 1], y[j - 1]) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        // Where in y did the final matched word land? Tells us how far through the slide the singer is.
        var i = x.count, j = y.count, last = -1
        while i > 0 && j > 0 {
            if similar(x[i - 1], y[j - 1]) && dp[i][j] == dp[i - 1][j - 1] + 1 {
                if last < 0 { last = j - 1 }
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        return (dp[x.count][y.count], last)
    }

    /// Score how well the most recent heard words match a slide (0...1).
    func score(_ heard: [String], slide j: Int) -> (score: Double, progress: Double) {
        guard let toks = slideTokens[safe: j], !toks.isEmpty, !heard.isEmpty else { return (0, 0) }
        let window = Array(heard.suffix(min(8, max(3, toks.count))))
        let (len, last) = Self.lcs(window, toks)
        let denom = Double(min(window.count, toks.count))
        let s = denom > 0 ? Double(len) / denom : 0
        let progress = last >= 0 ? Double(last + 1) / Double(toks.count) : 0
        return (s, progress)
    }

    /// Feed the latest heard words; returns what to do.
    mutating func update(heardText: String, current: Int?, now: Date = Date()) -> Decision {
        let heard = Self.tokens(heardText)
        guard heard.count >= 2, !slideTokens.isEmpty else {
            return Decision(kind: .hold, confidence: 0, bestIndex: current)
        }
        let c = current ?? -1
        var best = -1
        var bestWeighted = 0.0
        var bestRaw = 0.0
        var second = 0.0
        var currentProgress = 0.0
        var currentScore = 0.0

        for j in slideTokens.indices {
            let (s, p) = score(heard, slide: j)
            if j == c { currentProgress = p; currentScore = s }
            // Prefer staying put or moving forward; jumps and going back need stronger evidence.
            let d = j - c
            let prior: Double
            switch d {
            case 0: prior = 1.0
            case 1: prior = 1.0
            case 2: prior = 0.9
            case 3...: prior = 0.78 - min(0.15, Double(d) * 0.01)
            default: prior = 0.7 - min(0.15, Double(-d) * 0.01)
            }
            let w = s * prior
            // Ties (a repeated chorus) go to the nearest forward instance.
            if w > bestWeighted + 0.0001 || (abs(w - bestWeighted) < 0.0001 && best >= 0 && abs(d) < abs(best - c) && d >= 0) {
                second = max(second, bestWeighted)
                bestWeighted = w; best = j; bestRaw = s
            } else {
                second = max(second, w)
            }
        }

        let margin = max(0, bestWeighted - second)
        let confidence = min(1, bestRaw * 0.75 + margin * 1.5)

        if bestRaw >= 0.5 { lastMatchAt = now }
        if now.timeIntervalSince(lastMatchAt) > 8 {
            return Decision(kind: .offScript, confidence: 0, bestIndex: current)
        }

        // Stability: a candidate must win twice in a row before we move.
        if best == stableCandidate { stableCount += 1 } else { stableCandidate = best; stableCount = 1 }

        // Early advance: the singer reached the last words of the current slide.
        if advanceAtEndOfSlide, c >= 0, c + 1 < slideTokens.count, currentScore >= 0.7, currentProgress >= 0.9,
           (slideTokens[c].count >= 3) {
            let tail = Array(slideTokens[c].suffix(2))
            let heardTail = Array(heard.suffix(2))
            if zip(tail, heardTail).allSatisfy({ Self.similar($0, $1) }) {
                return Decision(kind: .advance(to: c + 1), confidence: max(confidence, currentScore), bestIndex: c)
            }
        }

        // Going backwards (e.g. repeating a verse) needs near-certain evidence.
        let backwardOK = best > c || bestRaw >= 0.85
        if best >= 0, best != c, bestWeighted >= threshold, stableCount >= 2, backwardOK {
            let kind: Decision.Kind = (best == c + 1) ? .advance(to: best) : .jump(to: best)
            return Decision(kind: kind, confidence: confidence, bestIndex: best)
        }
        return Decision(kind: .hold, confidence: confidence, bestIndex: best >= 0 ? best : current)
    }
}
