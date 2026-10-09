import SwiftUI
import UniformTypeIdentifiers

struct MediaPanel: View {
    @Environment(AppModel.self) private var app
    @State private var url = ""
    @State private var ndiSources: [String] = []
    @State private var searchingNDI = false
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nowPlaying

                PanelHeader(title: "Media library")
                let media = app.store.data.presentations.filter { $0.kind == .media }
                if media.isEmpty { Text("Import images or videos with + in the sidebar.").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(media) { p in
                        Button {
                            if p.orderedSlides.count > 1 { app.selectedPresentationID = p.id }
                            else if let m = p.groups.first?.slides.first?.media { app.engine.playMedia(m) }
                        } label: {
                            VStack(spacing: 2) {
                                ZStack {
                                    Color.black
                                    if let m = p.groups.first?.slides.first?.media, m.kind == .image, let img = ThumbnailCache.shared.image(m.location) {
                                        Image(nsImage: img).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "film").font(.title).foregroundStyle(.secondary)
                                    }
                                }
                                .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(p.name).font(.caption2).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                PanelHeader(title: "Live inputs (Apple TV, cameras, DeckLink in)")
                let devices = CaptureManager.devices()
                if devices.isEmpty {
                    Text("No capture devices found. Connect an Apple TV through a capture card or DeckLink input (needs Blackmagic Desktop Video).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(devices) { d in
                    HStack {
                        Label(d.name, systemImage: d.name.lowercased().contains("decklink") ? "rectangle.connected.to.line.below" : "video")
                        Spacer()
                        Button("Show") { app.engine.playMedia(MediaRef(kind: .capture, location: d.id, name: d.name)) }
                    }
                }

                PanelHeader(title: "NDI sources")
                HStack {
                    Button(searchingNDI ? "Searching…" : "Find NDI Sources") {
                        searchingNDI = true
                        Task { ndiSources = await app.ndiIn.sources(); searchingNDI = false }
                    }
                    .disabled(searchingNDI)
                    if !app.ndiIn.available {
                        Text(LMNDI.sdkCompiledIn() ? "Install NDI Tools" : "Build with NDI SDK — see README")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                ForEach(ndiSources, id: \.self) { s in
                    HStack {
                        Label(s, systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        Button("Show") { app.engine.playMedia(MediaRef(kind: .ndi, location: s, name: s)) }
                    }
                }

                PanelHeader(title: "Web browser")
                HStack {
                    TextField("youtube.com/watch?v=…  or any URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { open() }
                    Button("Go Live") { open() }.disabled(url.isEmpty)
                }
                HStack {
                    Button("Show Browser Window") { app.browser.showWindow() }
                    Button("Fill With Video") { app.browser.fillWithVideo() }.help("Makes the page's video fill the frame")
                    Button("Reload") { app.browser.reload() }
                }
                .controlSize(.small)
                if let e = app.browser.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                if app.browser.isCapturing {
                    Label("Sending \(app.browser.title.isEmpty ? app.browser.urlString : app.browser.title)", systemImage: "record.circle")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            .padding(10)
        }
    }

    private func open() {
        app.engine.playMedia(MediaRef(kind: .web, location: url, scale: .fit))
    }

    @ViewBuilder private var nowPlaying: some View {
        if let m = app.engine.mediaLayer {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(m.displayName, systemImage: "play.rectangle.fill").font(.headline).lineLimit(1)
                    Spacer()
                    Button { app.engine.clear(.media) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
                if m.kind == .video {
                    HStack {
                        Button { app.media.togglePause() } label: { Image(systemName: app.media.isPlaying ? "pause.fill" : "play.fill") }
                        Slider(value: Binding(get: { app.media.position }, set: { app.media.seek(to: $0) }),
                               in: 0...max(1, app.media.duration))
                        Text("\(TimerRuntime.format(app.media.position)) / \(TimerRuntime.format(app.media.duration))")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .card()
        }
        if let a = app.media.audioTrack {
            HStack {
                Label(a.displayName, systemImage: "speaker.wave.2.fill").lineLimit(1)
                Spacer()
                Button("Stop") { app.engine.clear(.audio) }
            }
            .card()
        }
    }
}
