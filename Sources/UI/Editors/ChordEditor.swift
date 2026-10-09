import SwiftUI
import UniformTypeIdentifiers

/// Import a chord chart and fix anything it got wrong. Each slide is edited in ChordPro
/// style — "[G]Amazing [C]grace" — so moving a chord is just moving its bracket.
struct ChordEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var p: Presentation
    var maxLines: Int

    @State private var report: ChordMatcher.Report?
    @State private var error: String?
    @State private var previewStyle: ChordStyle = .nashville
    @State private var importing = false
    @State private var showUnmatched = false

    static let keys = ["C", "C#", "Db", "D", "Eb", "E", "F", "F#", "Gb", "G", "Ab", "A", "Bb", "B",
                       "Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if p.groups.isEmpty {
                ContentUnavailableView("No lyrics yet", systemImage: "music.note.list",
                                       description: Text("Import a chord chart and Lumen will build the slides from it."))
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
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "cho") ?? .plainText,
                                            UTType(filenameExtension: "chordpro") ?? .plainText],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
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
        HStack(spacing: 12) {
            Button {
                importing = true
            } label: { Label("Import Chord Chart…", systemImage: "doc.text.viewfinder") }
            .help("PDF (text or scanned), ChordPro, or chords-over-lyrics text")

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
        .padding(10)
    }

    private func importChart(_ url: URL) {
        do {
            let chart = try ChordChartReader.read(url: url)
            report = ChordMatcher.apply(chart, to: &p, maxLines: maxLines)
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
