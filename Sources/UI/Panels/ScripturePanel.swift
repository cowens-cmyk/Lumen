import SwiftUI

struct ScripturePanel: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var more: [(tag: String, label: String)] = []
    @State private var lastRef: BibleReference?
    @State private var result: Presentation?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        @Bindable var store = app.store
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("John 3:16-18, Ps 23, 1 Cor 13…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await lookup() } }
                    Button("Go") { Task { await lookup() } }.disabled(query.isEmpty || loading)
                }
                HStack {
                    BibleVersionPicker(more: more)
                    Stepper("\(store.data.settings.bibleVersesPerSlide)/slide", value: $store.data.settings.bibleVersesPerSlide, in: 1...6)
                        .fixedSize()
                }
                .font(.caption)
                Toggle("Keep line breaks", isOn: Binding(get: { store.data.settings.bibleKeepLineBreaks ?? false },
                                                         set: { store.data.settings.bibleKeepLineBreaks = $0 }))
                    .font(.caption)
                    .help("Off (default): scripture runs as straight text. On: keeps the line breaks the translation has, such as poetry.")
                if let v = BibleVersionPicker.currentCurated(app.scripture), !app.scripture.status(for: v).isReady {
                    Label(app.scripture.status(for: v).detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }

                if let p = result {
                    let slides = p.orderedSlides
                    HStack {
                        Text(p.name).font(.headline)
                        Spacer()
                        Button("Show") { app.engine.trigger(p, index: 0) }.buttonStyle(.borderedProminent)
                        Menu {
                            Button("Open in Slide Grid") { app.keep(p); app.selectedPresentationID = p.id }
                            Button("Save to Library") { app.keep(p); app.flash("Saved \(p.name)") }
                            Button("Add to Current Playlist") { app.keep(p); app.addToSelectedPlaylist(p.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    ForEach(Array(slides.enumerated()), id: \.offset) { i, ref in
                        Button {
                            app.engine.trigger(p, index: i)
                        } label: {
                            Text(ref.slide.text)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(app.engine.livePresentationID == p.id && app.engine.liveIndex == i && !app.engine.slideCleared
                                            ? Color.red.opacity(0.25) : Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !app.listening.detections.isEmpty {
                    Divider()
                    PanelHeader(title: "Heard in the sermon")
                    ForEach(app.listening.detections) { d in
                        DetectionRow(d: d) { ref in
                            query = ref.display
                            Task { await lookup(show: true) }
                        }
                    }
                } else if app.listening.isListening && app.listening.detectScripture {
                    Text("Listening for scripture references…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .task {
            await app.scripture.refreshCatalog()
            more = await app.scripture.moreOptions()
        }
        // Changing the version or the line-break option rebuilds the slides that are showing in the panel.
        .onChange(of: app.store.data.settings.bibleSelection) { _, _ in if lastRef != nil { Task { await lookup() } } }
        .onChange(of: app.store.data.settings.bibleKeepLineBreaks) { _, _ in if lastRef != nil { Task { await lookup() } } }
        .onChange(of: app.store.data.settings.bibleVersesPerSlide) { _, _ in if lastRef != nil { Task { await lookup() } } }
    }

    private func lookup(show: Bool = false) async {
        guard let ref = ReferenceParser.parse(query) else {
            error = "Couldn't read that reference. Try “John 3:16-18”."
            return
        }
        lastRef = ref
        loading = true
        error = nil
        defer { loading = false }
        do {
            let p = try await app.scripture.presentation(for: ref)
            result = p
            if show { app.engine.trigger(p, index: 0) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DetectionRow: View {
    @Environment(AppModel.self) private var app
    var d: ScriptureDetection
    var open: (BibleReference) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.reference.display).font(.headline)
                Text("“…\(d.heard.split(separator: " ").suffix(10).joined(separator: " "))”")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(d.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            Button("Display") { open(d.reference) }.buttonStyle(.borderedProminent).tint(d.strong ? .blue : .gray)
            Button { app.listening.dismiss(d) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .card()
    }
}


/// The church's Bible versions first (in the order they use), then everything else a source can supply.
struct BibleVersionPicker: View {
    @Environment(AppModel.self) private var app
    var more: [(tag: String, label: String)]

    static func currentCurated(_ svc: ScriptureService) -> CuratedVersion? {
        let sel = svc.selection
        guard sel.hasPrefix("v:") else { return nil }
        return BibleCatalog.curated(key: String(sel.dropFirst(2)))
    }

    var body: some View {
        let svc = app.scripture
        Picker("Bible", selection: Binding(get: { svc.selection }, set: { svc.selection = $0 })) {
            ForEach(svc.statuses) { st in
                Text("\(st.isReady ? "" : "⚠︎ ")\(st.version.name)").tag("v:\(st.version.key)")
            }
            if !more.isEmpty {
                Divider()
                ForEach(more, id: \.tag) { Text($0.label).tag($0.tag) }
            }
            if !svc.selection.hasPrefix("v:"), !more.contains(where: { $0.tag == svc.selection }) {
                Text(svc.selection).tag(svc.selection)
            }
        }
        .labelsHidden()
    }
}
