import SwiftUI

struct StageSnapshot {
    var layout: StageLayout
    var current: String
    var next: String
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

            if s.layout.showCurrent {
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
                    Text(s.nextGroup.isEmpty ? "NEXT" : "NEXT • \(s.nextGroup.uppercased())")
                        .font(.system(size: 24 * scale, weight: .heavy)).foregroundStyle(.gray)
                    Text(s.next.isEmpty ? "—" : s.next)
                        .font(.system(size: 56 * scale, weight: .semibold))
                        .foregroundStyle(s.layout.nextColor.color)
                        .lineLimit(3).minimumScaleFactor(0.4)
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
