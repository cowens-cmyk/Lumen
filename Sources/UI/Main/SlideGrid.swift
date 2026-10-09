import SwiftUI

struct SlideGrid: View {
    @Environment(AppModel.self) private var app
    @AppStorage("thumbSize") private var thumbSize = 220.0

    var body: some View {
        if let p = app.selectedPresentation ?? app.engine.livePresentation {
            VStack(spacing: 0) {
                header(p)
                Divider()
                ScrollView {
                    let slides = p.orderedSlides
                    if slides.isEmpty {
                        emptyState(p)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.6), spacing: 12)], spacing: 14) {
                        ForEach(Array(slides.enumerated()), id: \.offset) { i, ref in
                            SlideThumb(presentation: p, ref: ref, index: i,
                                       isLive: app.engine.livePresentationID == p.id && app.engine.liveIndex == i && !app.engine.slideCleared,
                                       isSuggested: app.listening.followLyrics && app.engine.livePresentationID == p.id && app.listening.suggestedIndex == i)
                                .onTapGesture { trigger(p, i) }
                        }
                    }
                    .padding(14)
                }
            }
        } else {
            ContentUnavailableView("Select a song or presentation", systemImage: "rectangle.on.rectangle",
                                   description: Text("Pick something from a playlist or the library. Click a slide to put it live."))
        }
    }

    private func trigger(_ p: Presentation, _ i: Int) {
        let inPlaylist = app.store.data.playlists.first { $0.id == app.selectedPlaylistID }?.items.contains {
            if case .presentation(let id) = $0.kind { id == p.id } else { false }
        } ?? false
        app.engine.trigger(p, index: i, playlistID: inPlaylist ? app.selectedPlaylistID : nil)
    }

    @ViewBuilder private func emptyState(_ p: Presentation) -> some View {
        VStack(spacing: 10) {
            Text("No slides yet").font(.headline)
            Button("Edit Slides…") { app.editingPresentationID = p.id }
        }
        .frame(maxWidth: .infinity).padding(40)
    }

    private func header(_ p: Presentation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.kind.symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if !p.author.isEmpty { Text(p.author) }
                    if !p.ccli.isEmpty { Text("CCLI \(p.ccli)") }
                    if p.pcoArrangementID != nil { Label("Planning Center", systemImage: "link") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store(p) == nil, !app.volunteerMode {
                Button("Save to Library") { app.keep(p) }
            }
            if p.kind == .media || p.slideshow.enabled {
                Button {
                    if app.engine.slideshowInterval == nil {
                        if app.engine.livePresentationID != p.id { app.engine.trigger(p, index: 0) }
                        app.engine.startSlideshow(interval: p.slideshow.interval)
                    } else { app.engine.stopSlideshow() }
                } label: {
                    Label(app.engine.slideshowInterval == nil ? "Slideshow" : "Stop", systemImage: app.engine.slideshowInterval == nil ? "play.rectangle" : "stop.fill")
                }
            }
            if !app.volunteerMode {
            Button { app.addToSelectedPlaylist(p.id) } label: { Image(systemName: "text.badge.plus") }
                .help("Add to current playlist")
                .disabled(app.selectedPlaylistID == nil)
            }
            if p.kind == .song, !app.volunteerMode {
                Button { app.editorInitialMode = 4; app.editingPresentationID = p.id } label: {
                    Label(p.key.map { "Chords · \($0)" } ?? "Chords", systemImage: "music.quarternote.3")
                }
                .disabled(store(p) == nil)
                .help("Import a chord chart PDF and edit the Nashville numbers shown on the stage display")
            }
            if !app.volunteerMode {
                Button("Edit") { app.editingPresentationID = p.id }
                    .disabled(store(p) == nil)
                Slider(value: $thumbSize, in: 140...360).frame(width: 90).help("Thumbnail size")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func store(_ p: Presentation) -> Presentation? { app.store.presentation(p.id) }
}

struct SlideThumb: View {
    @Environment(AppModel.self) private var app
    var presentation: Presentation
    var ref: SlideRef
    var index: Int
    var isLive: Bool
    var isSuggested: Bool

    var body: some View {
        let theme = app.store.resolvedTheme(for: presentation, slide: ref.slide)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                SlidePreview(text: ref.slide.text, label: ref.slide.label, theme: theme, media: ref.slide.media, background: presentation.background)
                if let m = ref.slide.media, m.kind != .image {
                    Image(systemName: m.kind == .video ? "film" : m.kind == .audio ? "speaker.wave.2" : "dot.radiowaves.left.and.right")
                        .padding(5).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white).padding(6)
                }
                if let m = ref.slide.media, m.kind == .video {
                    let choice = MediaEndChoice.of(m)
                    if choice != .stay {
                        Label(choice == .loop ? "Loop" : choice == .next ? "Then next" : choice == .clear ? "Then clear" : "Then actions",
                              systemImage: choice == .loop ? "repeat" : "forward.end.fill")
                            .font(.system(size: 9, weight: .bold)).labelStyle(.titleAndIcon)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                            .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                if !ref.slide.actions.isEmpty {
                    Image(systemName: "bolt.fill").font(.caption).padding(5)
                        .background(.yellow, in: Circle()).foregroundStyle(.black).padding(6)
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isLive ? Color.red : isSuggested ? Color.yellow : Color.white.opacity(0.08), lineWidth: isLive || isSuggested ? 3 : 1)
            )
            HStack(spacing: 6) {
                Rectangle().fill(ref.groupColor.color).frame(width: 4, height: 12)
                Text("\(index + 1)  \(ref.groupName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if !ref.slide.label.isEmpty { Text(ref.slide.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !app.volunteerMode, let m = ref.slide.media, m.kind == .video {
                Section("When this video ends") {
                    ForEach(MediaEndChoice.allCases.filter { $0 != .custom }) { c in
                        Button {
                            app.store.updateSlide(in: presentation.id, slideID: ref.slide.id) { s in
                                if var media = s.media { c.apply(to: &media); s.media = media }
                            }
                        } label: {
                            Label(c.title, systemImage: MediaEndChoice.of(m) == c ? "checkmark" : "")
                        }
                    }
                }
            }
        }
    }
}
