import SwiftUI

struct ScripturePanel: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var translations: [BibleTranslation] = []
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
                    Picker("Translation", selection: $store.data.settings.bibleTranslation) {
                        ForEach(translations) { t in Text("\(t.abbreviation) — \(t.name)").tag(t.id) }
                        if !translations.contains(where: { $0.id == store.data.settings.bibleTranslation }) {
                            Text(store.data.settings.bibleTranslation.uppercased()).tag(store.data.settings.bibleTranslation)
                        }
                    }
                    .labelsHidden()
                    Stepper("\(store.data.settings.bibleVersesPerSlide)/slide", value: $store.data.settings.bibleVersesPerSlide, in: 1...6)
                        .fixedSize()
                }
                .font(.caption)

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
        .task { translations = await app.scripture.translations() }
        .onChange(of: app.store.data.settings.bibleProvider) { _, _ in
            Task { translations = await app.scripture.translations() }
        }
    }

    private func lookup(show: Bool = false) async {
        guard let ref = ReferenceParser.parse(query) else {
            error = "Couldn't read that reference. Try “John 3:16-18”."
            return
        }
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
