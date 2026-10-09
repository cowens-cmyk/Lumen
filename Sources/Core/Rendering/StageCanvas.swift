import SwiftUI

struct StageSnapshot {
    var layout: StageLayout
    var current: String
    var currentChords: [ChordPlacement] = []
    var next: String
    var nextChords: [ChordPlacement] = []
    var key: String? = nil
    var nextGroup: String
    var notes: String
    var clock: String
    var timers: [(String, String)]
    var message: String?
}

/// Confidence monitor for the stage. Big, high-contrast, readable from 40 feet.
struct StageCanvas: View {
    var s: StageSnapshot

    var body: some View {
        let scale = s.layout.textScale
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if s.layout.showClock {
                    Text(s.clock).font(.system(size: 64 * scale, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                }
                Spacer()
                ForEach(Array(s.timers.enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(t.0.uppercased()).font(.system(size: 22 * scale, weight: .semibold)).foregroundStyle(.gray)
                        Text(t.1).font(.system(size: 64 * scale, weight: .bold, design: .monospaced))
                            .foregroundStyle(t.1.hasPrefix("-") ? .red : .white)
                    }
                    .padding(.leading, 40)
                }
            }
            .padding(.horizontal, 50).padding(.top, 30)

            if s.layout.showMessage, let m = s.message {
                Text(m).font(.system(size: 54 * scale, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 30).padding(.vertical, 10)
                    .background(Color.yellow, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 10)
            }

            if s.layout.showCurrent, s.layout.showChords != false, !s.currentChords.isEmpty {
                let size = ChordedLyricsView.fittingSize(text: s.current, hasChords: true, base: 92 * scale,
                                                         width: designSize.width - 120, height: 640)
                ChordedLyricsView(text: s.current, chords: s.currentChords, key: s.key,
                                  style: s.layout.chordStyle ?? .nashville, fontSize: size,
                                  textColor: s.layout.currentColor.color,
                                  chordColor: (s.layout.chordColor ?? RGBA(hex: "#38BDF8")).color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 60)
            } else if s.layout.showCurrent {
                Text(s.current.isEmpty ? " " : s.current)
                    .font(.system(size: 92 * scale, weight: .bold))
                    .foregroundStyle(s.layout.currentColor.color)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 60)
            }

            if s.layout.showNotes, !s.notes.isEmpty {
                Text(s.notes).font(.system(size: 40 * scale)).foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 60).lineLimit(4)
            }

            if s.layout.showNext {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.nextGroup.isEmpty ? "NEXT" : "NEXT • \(s.nextGroup.uppercased())")
                        Spacer()
                        if s.layout.showChords != false, let k = s.key { Text("KEY \(k)") }
                    }
                    .font(.system(size: 24 * scale, weight: .heavy)).foregroundStyle(.gray)
                    if s.layout.showChords != false, !s.nextChords.isEmpty {
                        ChordedLyricsView(text: s.next, chords: s.nextChords, key: s.key,
                                          style: s.layout.chordStyle ?? .nashville,
                                          fontSize: ChordedLyricsView.fittingSize(text: s.next, hasChords: true, base: 44 * scale,
                                                                                  width: designSize.width - 160, height: 200),
                                          textColor: s.layout.nextColor.color,
                                          chordColor: (s.layout.chordColor ?? RGBA(hex: "#38BDF8")).color.opacity(0.85),
                                          alignment: .leading)
                    } else {
                        Text(s.next.isEmpty ? "—" : s.next)
                            .font(.system(size: 56 * scale, weight: .semibold))
                            .foregroundStyle(s.layout.nextColor.color)
                            .lineLimit(3).minimumScaleFactor(0.4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 60).padding(.vertical, 30)
                .background(Color.white.opacity(0.08))
            }
        }
        .frame(width: designSize.width, height: designSize.height)
        .background(s.layout.background.color)
    }
}

/// Lyrics with chords (Nashville numbers or letters) sitting above the syllable they belong to.
struct ChordedLyricsView: View {
    var text: String
    var chords: [ChordPlacement]
    var key: String?
    var style: ChordStyle
    var fontSize: Double
    var textColor: Color
    var chordColor: Color
    var alignment: HorizontalAlignment = .center

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: alignment, spacing: fontSize * 0.15) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let segs = ChordLayout.segments(line: line, chords: chords.filter { $0.line == i })
                let hasChords = segs.contains { $0.chord != nil }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        VStack(alignment: .leading, spacing: 0) {
                            if hasChords {
                                Text(seg.chord.map { ChordLayout.label($0, key: key, style: style) + " " } ?? " ")
                                    .font(.system(size: fontSize * 0.62, weight: .heavy, design: .rounded))
                                    .foregroundStyle(chordColor)
                                    .fixedSize()
                            }
                            Text(seg.text)
                                .font(.system(size: fontSize, weight: .bold))
                                .foregroundStyle(textColor)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    /// Picks a font size so the longest line and all lines fit the given box.
    static func fittingSize(text: String, hasChords: Bool, base: Double, width: Double, height: Double) -> Double {
        let lines = text.components(separatedBy: "\n")
        let longest = Double(lines.map(\.count).max() ?? 1)
        let byWidth = width / max(1, longest * 0.56)
        let lineHeight = hasChords ? 2.0 : 1.25
        let byHeight = height / max(1, Double(lines.count) * lineHeight)
        return max(24, min(base, byWidth, byHeight))
    }
}
