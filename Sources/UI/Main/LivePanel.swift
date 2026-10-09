import SwiftUI

struct LivePanel: View {
    @Environment(AppModel.self) private var app
    @AppStorage("liveTab") private var tab = "scripture"

    var body: some View {
        VStack(spacing: 0) {
            previews
            Divider()
            Picker("", selection: $tab) {
                Image(systemName: "book.closed").help("Scripture").tag("scripture")
                Image(systemName: "photo.on.rectangle").help("Media, inputs & browser").tag("media")
                Image(systemName: "rectangle.bottomthird.inset.filled").help("Props & lower thirds").tag("props")
                Image(systemName: "timer").help("Timers").tag("timers")
                Image(systemName: "text.bubble").help("Messages").tag("messages")
                Image(systemName: "waveform").help("AI listening").tag("listen")
                Image(systemName: "calendar.badge.clock").help("Schedule").tag("schedule")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Group {
                switch tab {
                case "media": MediaPanel()
                case "props": PropsPanel()
                case "timers": TimersPanel()
                case "messages": MessagesPanel()
                case "listen": ListenPanel()
                case "schedule": SchedulePanel()
                default: ScripturePanel()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var previews: some View {
        VStack(spacing: 8) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
            ForEach(app.store.data.screens.filter(\.enabled)) { screen in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(screen.name).font(.caption.bold())
                        Text(screen.role.title).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        let status = app.outputs.statusByScreen[screen.id] ?? []
                        Text(status.isEmpty ? "No output assigned" : status.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(status.contains { $0.contains("live") } ? .green : .secondary)
                            .lineLimit(1)
                    }
                    Color.black
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            ZStack {
                                if screen.role != .audience { Checkerboard() }
                                ScreenPreview(renderer: app.outputs.renderers[screen.id])
                                    .id(app.outputs.renderers[screen.id].map(ObjectIdentifier.init))
                            }
                        }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
          }
            if let p = app.engine.livePresentation, let i = app.engine.liveIndex {
                HStack {
                    Text("LIVE").font(.caption2.bold()).padding(.horizontal, 5).background(.red, in: Capsule()).foregroundStyle(.white)
                    Text("\(p.name) — \(i + 1)/\(p.orderedSlides.count)").font(.caption).lineLimit(1)
                    Spacer()
                    if let next = app.engine.nextSlide {
                        Text("Next: \(next.slide.text.components(separatedBy: "\n").first ?? "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
    }
}
