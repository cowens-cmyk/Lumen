import SwiftUI
import UniformTypeIdentifiers

struct PresentationEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let presentationID: UUID

    @State private var p = Presentation(name: "")
    @State private var lyricText = ""
    @State private var mode = 0
    @State private var selectedSlide: UUID?
    @State private var loaded = false
    @State private var incomingChart: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Name", text: $p.name).font(.title2.bold()).textFieldStyle(.plain)
                Picker("", selection: $mode) {
                    Text("Text").tag(0)
                    Text("Slides").tag(1)
                    Text("Arrangement").tag(2)
                    Text("Chords").tag(4)
                    Text("Info").tag(3)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Group {
                switch mode {
                case 1: slidesMode
                case 2: ArrangementEditor(p: $p)
                case 4: ChordEditor(p: $p, maxLines: theme.maxLinesPerSlide, incoming: $incomingChart)
                case 3: infoMode
                default: textMode
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 680)
        // A chord chart dropped anywhere on the editor goes to the Chords tab and is imported.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: ChordEditor.isChartFile) else { return false }
            incomingChart = url
            mode = 4
            return true
        }
        .onChange(of: mode) { old, new in
            if old == 0 { applyText() }
            if new == 0 { lyricText = LyricParser.text(for: p) }
        }
        .onAppear {
            guard !loaded, let found = app.store.presentation(presentationID) else { return }
            p = found
            lyricText = LyricParser.text(for: found)
            mode = app.editorInitialMode
            app.editorInitialMode = 0
            loaded = true
        }
    }

    private var theme: Theme { app.store.resolvedTheme(for: p) }

    private func save() {
        if mode == 0 { applyText() }
        app.store.upsert(p)
    }

    private func applyText() {
        let arrangement = p.arrangement
        LyricParser.apply(text: lyricText, to: &p, maxLines: theme.maxLinesPerSlide)
        // Group IDs survive re-parsing when names match, so keep whatever of the arrangement still exists.
        let ids = Set(p.groups.map(\.id))
        p.arrangement = arrangement.filter(ids.contains)
    }

    // MARK: Text mode — fastest way to fix lyrics

    private var textMode: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Type a heading line (Verse 1, Chorus, Bridge, Tag…) to start a group. Blank lines split slides. Lines per slide come from the theme (\(theme.maxLinesPerSlide)).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $lyricText)
                    .font(.system(size: 14, design: .monospaced))
                    .onChange(of: lyricText) { _, _ in applyText() }
            }
            .padding()
            .frame(minWidth: 380)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(p.groups) { g in
                        ForEach(g.slides) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                SlidePreview(text: s.text, label: s.label, theme: theme).clipShape(RoundedRectangle(cornerRadius: 4))
                                GroupChip(name: g.name, color: g.color)
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(minWidth: 400)
        }
    }

    // MARK: Slides mode — per-slide label, notes, media, actions

    private var slidesMode: some View {
        HSplitView {
            List(selection: $selectedSlide) {
                ForEach($p.groups) { $g in
                    Section {
                        ForEach(g.slides) { s in
                            Text(s.text.isEmpty ? "(blank)" : s.text).lineLimit(2).tag(s.id)
                        }
                        .onMove { g.slides.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add Slide") { g.slides.append(Slide()) }.buttonStyle(.link)
                    } header: {
                        HStack {
                            TextField("Group", text: $g.name).textFieldStyle(.plain).font(.headline)
                            ColorPicker("", selection: ColorBinding.make($g.color)).labelsHidden()
                            Button(role: .destructive) {
                                let id = g.id
                                p.groups.removeAll { $0.id == id }
                                p.arrangement.removeAll { $0 == id }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Group") {
                    p.groups.append(SlideGroup(name: "Group \(p.groups.count + 1)", color: SlideGroup.color(for: "x"), slides: [Slide()]))
                }
            }
            .frame(minWidth: 300, maxWidth: 380)

            if let id = selectedSlide, let (gi, si) = locate(id) {
                SlideDetail(slide: $p.groups[gi].slides[si], theme: theme) {
                    p.groups[gi].slides.remove(at: si)
                    selectedSlide = nil
                }
            } else {
                ContentUnavailableView("Select a slide", systemImage: "rectangle.on.rectangle")
            }
        }
    }

    private func locate(_ id: UUID) -> (Int, Int)? {
        for (gi, g) in p.groups.enumerated() {
            if let si = g.slides.firstIndex(where: { $0.id == id }) { return (gi, si) }
        }
        return nil
    }

    // MARK: Info

    private var infoMode: some View {
        Form {
            Picker("Type", selection: $p.kind) {
                ForEach(PresentationKind.allCases) { k in Label(k.title, systemImage: k.symbol).tag(k) }
            }
            Picker("Theme", selection: $p.themeID) {
                Text("Default for \(p.kind.title) (\(app.store.resolvedTheme(for: Presentation(name: "", kind: p.kind)).name))").tag(UUID?.none)
                ForEach(app.store.data.themes) { t in Text(t.name).tag(Optional(t.id)) }
            }
            Section("Background behind the words") {
                BackgroundPicker(media: $p.background, emptyLabel: "Use the theme's background")
                Text("Set a looping video or image once and every slide of this song uses it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Author", text: $p.author)
            TextField("Copyright", text: $p.copyright)
            TextField("CCLI Song #", text: $p.ccli)
            TextField("Notes", text: $p.notes, axis: .vertical)
            Section("Slideshow") {
                Toggle("Auto-advance when triggered", isOn: $p.slideshow.enabled)
                Stepper("Every \(Int(p.slideshow.interval)) seconds", value: $p.slideshow.interval, in: 1...120)
                Toggle("Loop", isOn: $p.slideshow.loop)
            }
            if p.pcoSongID != nil {
                Section("Planning Center") {
                    Toggle("Keep my edits (don't overwrite on sync)", isOn: $p.lockedFromSync)
                    Text("Lyrics come from the song's arrangement in Planning Center (usually imported from SongSelect).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SlideDetail: View {
    @Environment(AppModel.self) private var app
    @Binding var slide: Slide
    var theme: Theme
    var delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SlidePreview(text: slide.text, label: slide.label, theme: app.store.theme(slide.themeOverride) ?? theme, media: slide.media)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 560)
                Text("Text").font(.headline)
                TextEditor(text: $slide.text).font(.body).frame(height: 100).border(.separator)
                TextField("Label / reference (e.g. John 3:16 ESV)", text: $slide.label)
                TextField("Stage notes", text: $slide.notes, axis: .vertical)
                Picker("Theme override", selection: $slide.themeOverride) {
                    Text("None").tag(UUID?.none)
                    ForEach(app.store.data.themes) { t in Text(t.name).tag(Optional(t.id)) }
                }
                HStack {
                    Text("Background").font(.headline)
                    if let m = slide.media {
                        Text(m.displayName).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { m.scale }, set: { slide.media?.scale = $0 })) {
                            Text("Fill").tag(ScaleMode.fill); Text("Fit").tag(ScaleMode.fit); Text("Stretch").tag(ScaleMode.stretch)
                        }.labelsHidden().fixedSize()
                        Button("Remove") { slide.media = nil }
                    }
                    Spacer()
                    Button("Choose…") { chooseMedia() }
                }
                if let m = slide.media, m.kind == .video {
                    MediaEndPicker(media: Binding(get: { slide.media ?? m }, set: { slide.media = $0 }))
                    if MediaEndChoice.of(m) == .custom {
                        ActionListEditor(actions: Binding(get: { slide.media?.onEnd ?? [] }, set: { slide.media?.onEnd = $0 }))
                            .frame(height: 160)
                    }
                }
                Toggle("Enabled", isOn: $slide.enabled)
                ActionListEditor(actions: $slide.actions).frame(height: 200)
                Button("Delete Slide", role: .destructive, action: delete)
            }
            .padding()
        }
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        let local = app.store.importMedia(u)
        let isImage = UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true
        slide.media = MediaRef(kind: isImage ? .image : .video, location: local.path,
                               name: u.deletingPathExtension().lastPathComponent, scale: app.store.defaultMediaScale)
    }
}

struct ArrangementEditor: View {
    @Binding var p: Presentation

    private var order: [UUID] { p.arrangement.isEmpty ? p.groups.map(\.id) : p.arrangement }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Arrangement").font(.headline)
            Text("The order groups are shown in. Click a group below to add it; repeat choruses as many times as you sing them. Planning Center sync fills this from the arrangement's sequence.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(order.enumerated()), id: \.offset) { i, gid in
                        if let g = p.groups.first(where: { $0.id == gid }) {
                            HStack(spacing: 4) {
                                Text(g.name)
                                Button {
                                    var o = order; o.remove(at: i); p.arrangement = o
                                } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(g.color.color.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
            Divider()
            Text("Groups").font(.headline)
            HStack {
                ForEach(p.groups) { g in
                    Button(g.name) { p.arrangement = order + [g.id] }
                        .buttonStyle(.borderedProminent).tint(g.color.color)
                }
            }
            HStack {
                Button("Reset to Group Order") { p.arrangement = [] }
                Button("Clear") { p.arrangement = [p.groups.first?.id].compactMap { $0 } }
            }
            Spacer()
        }
        .padding()
    }
}
