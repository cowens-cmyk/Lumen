import XCTest
@testable import Lumen

/// Runs the chart reader on real chord charts kept outside the repository (they're licensed, so they're never
/// committed). Point TEST_RUNNER_LUMEN_CHART_DIR at a folder of PDFs to see exactly what Lumen makes of each one.
@MainActor
final class LocalChartTests: XCTestCase {
    func testRealCharts() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_CHART_DIR"] else { throw XCTSkip("LUMEN_CHART_DIR not set") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            let chart = try ChordChartReader.read(url: url)
            var out = "\n===== \(url.lastPathComponent)\n"
            out += "looksLikeChart=\(ChordChartReader.looksLikeChart(url: url)) title=\(chart.title) | artist=\(chart.artist) | key=\(chart.key ?? "-") | ccli=\(chart.ccli)\n"
            out += "roadmap: \(chart.roadmap.joined(separator: ", "))\n"
            for s in chart.sections {
                out += "  [\(s.name)]\(s.note.isEmpty ? "" : "  (note: \(s.note))")\(s.hasContent ? "" : "  <repeat>")\n"
                for l in s.lines {
                    out += "     " + ChordPro.encode(text: l.lyric, chords: l.chords.map { ChordPlacement(line: 0, index: $0.index, chord: $0.chord) }) + "\n"
                }
            }
            var p = Presentation(name: "", kind: .song)
            let r = ChordMatcher.apply(chart, to: &p, maxLines: 2)
            out += "SONG \(p.name) key=\(p.key ?? "-") author=\(p.author) | \(r.summary)\n"
            out += "ORDER: " + p.arrangement.compactMap { id in p.groups.first { $0.id == id }?.name }.joined(separator: " → ") + "\n"
            for g in p.groups {
                out += "  {\(g.name)}\n"
                for s in g.slides {
                    out += "     | " + ChordPro.encode(text: s.text, chords: s.chords ?? []).replacingOccurrences(of: "\n", with: "\n     | ")
                    out += s.notes.isEmpty ? "\n" : "    ← notes: \(s.notes)\n"
                }
            }
            print(out)
            try out.write(to: URL(fileURLWithPath: dir).appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".parsed.txt"), atomically: true, encoding: .utf8)
        }
    }
}
