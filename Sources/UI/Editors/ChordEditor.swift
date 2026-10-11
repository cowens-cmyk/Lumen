import SwiftUI
import UniformTypeIdentifiers

/// Import a chord chart and fix anything it got wrong. Each slide is edited in ChordPro
/// style — "[G]Amazing [C]grace" — so moving a chord is just moving its bracket.
struct ChordEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var p: Presentation
    var maxLines: Int
    /// A chart dropped on the editor window; imported as soon as this tab sees it.
    @Binding var incoming: URL?

    @State private var report: ChordMatcher.Report?
    @State private var error: String?
    @State private var previewStyle: ChordStyle = .nashville
    @State private var importing = false
    @State private var showUnmatched = false
    @State private var useChartOrder = true
    @State private var replaceLyrics = false
    @State private var dropTargeted = false

    static let keys = ["C", "C#", "Db", "D", "Eb", "E", "F", "F#", "Gb", "G", "Ab", "A", "Bb", "B",
                       "Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if p.groups.isEmpty {
                ContentUnavailableView("No lyrics yet", systemImage: "music.note.list",
                                       description: Text("Drop a chord chart PDF here, or use Import Chord Chart. Lumen builds the lyrics, song order, key and chords from it."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach($p.groups) { $g in
                            VStack(alignment: .leading, spacing: 8) {
                                GroupChip(name: g.name, color: g.color)
                                ForEach($g.slides) { $slide in
                                    SlideChordRow(slide: $slide, key: p.key, style: previewStyle)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08)).padding(6).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isChartFile) else { return false }
            importChart(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: incoming) { _, url in
            guard let url else { return }
            incoming = nil
            importChart(url)
        }
        .onAppear {
            if let url = incoming { incoming = nil; importChart(url) }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "cho") ?? .plainText,
                                            UTType(filenameExtension: "chordpro") ?? .plainText],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importChart(url)
        }
        .sheet(isPresented: $showUnmatched) {
            VStack(alignment: .leading) {
                Text("Chart lines that didn't match a slide").font(.headline)
                Text("Usually extra repeats, tags or lines written differently in the chart. Add those chords by hand below if you need them.")
                    .font(.caption).foregroundStyle(.secondary)
                List(report?.unmatchedChartLines ?? [], id: \.self) { Text($0) }
                HStack { Spacer(); Button("Done") { showUnmatched = false }.keyboardShortcut(.defaultAction) }
            }
            .padding().frame(width: 480, height: 400)
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) { toolbarContent.padding(10) }
    }

    private var toolbarContent: some View {
        HStack(spacing: 12) {
            Button {
                importing = true
            } label: { Label("Import Chord Chart…", systemImage: "doc.text.viewfinder") }
            .help("PDF (text or scanned), ChordPro, or chords-over-lyrics text. You can also drop the file onto this window.")

            Toggle("Use chart's song order", isOn: $useChartOrder)
                .toggleStyle(.checkbox)
                .help("Sets verse / chorus / bridge order from the chart.")
            Toggle("Replace lyrics with chart's", isOn: $replaceLyrics)
                .toggleStyle(.checkbox)
                .help("Off: keeps the words you have and adds chords. On: rebuilds the slides from the chart's lyrics.")

            Picker("Key", selection: Binding(get: { p.key ?? "" }, set: { p.key = $0.isEmpty ? nil : $0 })) {
                Text("Unknown").tag("")
                ForEach(Self.keys, id: \.self) { Text($0).tag($0) }
                if let k = p.key, !Self.keys.contains(k) { Text(k).tag(k) }
            }
            .fixedSize()
            .help("The key the chords are written in. Nashville numbers are counted from it.")

            Button("Guess Key") {
                let all = p.groups.flatMap { $0.slides.flatMap { ($0.chords ?? []).map(\.chord) } }
                p.key = Nashville.guessKey(all)
            }

            Menu("Transpose") {
                ForEach([-2, -1, 1, 2, 3, 5, 7], id: \.self) { n in
                    Button(n > 0 ? "Up \(n)" : "Down \(-n)") { transpose(n) }
                }
            }
            .fixedSize()
            .help("Changes the chord letters and key. Nashville numbers stay the same.")

            Picker("Preview", selection: $previewStyle) {
                ForEach(ChordStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()

            Spacer()
            if let report {
                Button(report.summary) { if !report.unmatchedChartLines.isEmpty { showUnmatched = true } }
                    .buttonStyle(.link).font(.caption)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Button("Clear Chords", role: .destructive) {
                for gi in p.groups.indices { for si in p.groups[gi].slides.indices { p.groups[gi].slides[si].chords = nil } }
                report = nil
            }
        }
        .fixedSize()
    }

    static func isChartFile(_ url: URL) -> Bool {
        ["pdf", "txt", "cho", "chordpro", "crd"].contains(url.pathExtension.lowercased())
    }

    private func importChart(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let chart = try ChordChartReader.read(url: url)
            report = ChordMatcher.apply(chart, to: &p, maxLines: maxLines, replaceLyrics: replaceLyrics, applyOrder: useChartOrder)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func transpose(_ n: Int) {
        var flats = false
        if let old = p.key {
            let sharpSpelling = Nashville.transpose(old, by: n, flats: false)
            flats = MusicKey(sharpSpelling)?.prefersFlats ?? false
            p.key = Nashville.transpose(old, by: n, flats: flats)
        }
        for gi in p.groups.indices {
            for si in p.groups[gi].slides.indices {
                p.groups[gi].slides[si].chords = p.groups[gi].slides[si].chords?.map { placement in
                    var c = placement; c.chord = Nashville.transpose(c.chord, by: n, flats: flats); return c
                }
            }
        }
    }
}

struct SlideChordRow: View {
    @Binding var slide: Slide
    var key: String?
    var style: ChordStyle
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 54, maxHeight: 110)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .onChange(of: draft) { _, new in
                    let (text, chords) = ChordPro.decode(new)
                    slide.text = text
                    slide.chords = chords.isEmpty ? nil : chords
                }
            ChordedLyricsView(text: slide.text, chords: slide.chords ?? [], key: key, style: style, fontSize: 15,
                              textColor: .primary, chordColor: .accentColor, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
        .onAppear { draft = ChordPro.encode(text: slide.text, chords: slide.chords ?? []) }
        .onChange(of: slide.chords) { _, _ in
            // Refresh after an import or transpose, but never fight the user's typing.
            if !focused { draft = ChordPro.encode(text: slide.text, chords: slide.chords ?? []) }
        }
    }
}
