import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var pasteLyrics = false
    @State private var importingChart = false

    var body: some View {
        @Bindable var app = app
        Group {
            if app.volunteerMode {
                VolunteerView()
            } else {
                operatorView
            }
        }
        .overlay(alignment: .top) {
            if let r = app.recovery {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lumen closed unexpectedly").font(.headline)
                        Text("Last on screen: \(r.presentationName ?? "a slide") — slide \((r.index ?? 0) + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Put It Back on Screen") { app.restoreSession() }.buttonStyle(.borderedProminent)
                    Button("Dismiss") { app.recovery = nil }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                Text(t).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(WindowTagger(identifier: OutputManager.mainWindowID))
        .animation(.easeInOut, value: app.toast)
        .animation(.easeInOut, value: app.recovery)
        .sheet(item: Binding(get: { app.editingPresentationID.map(IDBox.init) },
                             set: { app.editingPresentationID = $0?.id })) { box in
            PresentationEditor(presentationID: box.id).environment(app)
        }
        .sheet(isPresented: $pasteLyrics) { PasteLyricsSheet().environment(app) }
        .fileImporter(isPresented: $importingChart,
                      allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "cho") ?? .plainText,
                                            UTType(filenameExtension: "chordpro") ?? .plainText],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            urls.forEach { app.createSong(fromChart: $0) }
        }
        // Dropping files anywhere on the main window imports them (a chord chart PDF becomes a song).
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task {
                do {
                    let r = try await Importer(store: app.store).importFiles(urls)
                    app.selectedPresentationID = r.presentations.first?.id
                    app.flash("Imported \(r.presentations.count) item\(r.presentations.count == 1 ? "" : "s")"
                              + (r.failures.isEmpty ? "" : " — couldn't import: " + r.failures.joined(separator: "; ")))
                } catch { app.flash(error.localizedDescription) }
            }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Importer.allowedTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let access = urls.map { $0.startAccessingSecurityScopedResource() }
                defer { zip(urls, access).forEach { if $1 { $0.stopAccessingSecurityScopedResource() } } }
                do {
                    let r = try await Importer(store: app.store).importFiles(urls)
                    app.selectedPresentationID = r.presentations.first?.id
                    app.flash("Imported \(r.presentations.count) item\(r.presentations.count == 1 ? "" : "s")"
                              + (r.failures.isEmpty ? "" : " — couldn't import: " + r.failures.joined(separator: "; ")))
                } catch {
                    app.flash(error.localizedDescription)
                }
            }
        }
    }

    private var operatorView: some View {
        VStack(spacing: 0) {
        HSplitView {
            Sidebar(importing: $importing, pasteLyrics: $pasteLyrics, importingChart: $importingChart)
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 380, maxHeight: .infinity)
            SlideGrid()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            LivePanel()
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 560, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        BottomBar()
        }
        .toolbar { MainToolbar() }
    }
}

struct IDBox: Identifiable { var id: UUID }

/// Gives the hosting NSWindow a stable identifier so the app can tell its control window from sheets and outputs.
struct WindowTagger: NSViewRepresentable {
    var identifier: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.identifier = NSUserInterfaceItemIdentifier(identifier) }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { app.engine.previous() } label: { Image(systemName: "chevron.left") }.help("Previous slide (←)")
            Button { app.engine.next() } label: { Image(systemName: "chevron.right") }.help("Next slide (→ / space)")
        }
        ToolbarItem(placement: .principal) {
            LookPicker().frame(width: 220)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            UpdateToolbarButton()
            ListenToolbarIndicator()
            Button {
                Task { await app.pco.sync() }
            } label: {
                Label("Sync", systemImage: app.pco.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle")
            }
            .help(app.pco.lastSync.map { "Planning Center synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Sync Planning Center")
            .disabled(app.pco.isSyncing)
            Button {
                app.toggleOutputs()
            } label: {
                Label("Outputs", systemImage: app.outputs.outputsEnabled ? "display" : "display.trianglebadge.exclamationmark")
            }
            .help(app.outputs.outputsEnabled ? "Outputs live — click to disable (⇧⌘O)" : "Outputs disabled")
            Button {
                app.volunteerMode = true
            } label: {
                Label("Volunteer Mode", systemImage: "person.crop.circle.badge.checkmark")
            }
            .help("Switch to the simplified volunteer view")
            SettingsLink { Label("Setup", systemImage: "gearshape") }
        }
    }
}

struct LookPicker: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Picker("Look", selection: Binding(get: { app.engine.lookID ?? UUID() }, set: { app.engine.setLook($0) })) {
            ForEach(app.store.data.looks) { l in Text(l.name).tag(l.id) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help("Looks decide what each screen shows (full slide, lower third, transparent, hidden)")
    }
}

struct BottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(app.store.data.macros) { m in
                        Button { app.engine.runMacro(m.id) } label: {
                            Label(m.name, systemImage: m.symbol)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(m.color.color.opacity(0.85), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            ClearButtons(compact: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ClearButtons: View {
    @Environment(AppModel.self) private var app
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach([ClearTarget.slide, .media, .props, .messages], id: \.self) { t in
                Button(compact ? String(t.title.dropFirst(6)) : t.title) { app.engine.clear(t) }
                    .controlSize(compact ? .small : .regular)
            }
            Button("Clear All") { app.engine.clear(.all) }
                .controlSize(compact ? .small : .regular)
                .tint(.red)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct PasteLyricsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var chooseChart = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Song from Lyrics").font(.title2.bold())
            HStack {
                Image(systemName: "doc.text.viewfinder").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Have the chord chart? Drop the PDF here.").font(.callout.bold())
                    Text("Lumen builds the lyrics, song order, key and chords for the stage display in one step.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose PDF…") { chooseChart = true }
            }
            .padding(10)
            .background(dropTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6])))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: ChordEditor.isChartFile) else { return false }
                app.createSong(fromChart: url); dismiss()
                return true
            } isTargeted: { dropTargeted = $0 }
            .fileImporter(isPresented: $chooseChart, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "cho") ?? .plainText]) { result in
                if case .success(let url) = result { app.createSong(fromChart: url); dismiss() }
            }
            Divider()
            Text("Paste lyrics from SongSelect, Planning Center or anywhere. Section headings like **Verse 1**, **Chorus**, **[Bridge]** become groups; blank lines become slide breaks.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Song title", text: $title)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
                .border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let r = LyricParser.parseTXT(text, fallbackTitle: title.isEmpty ? "Untitled" : title)
                    let maxLines = app.store.resolvedTheme(for: Presentation(name: "", kind: .song)).maxLinesPerSlide
                    var p = LyricParser.presentation(name: title.isEmpty ? r.title : title, text: r.lyrics, maxLines: maxLines)
                    p.ccli = r.ccli
                    app.store.upsert(p)
                    app.selectedPresentationID = p.id
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
