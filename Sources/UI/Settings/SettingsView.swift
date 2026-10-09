import CoreImage.CIFilterBuiltins
import EventKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ScreensSettings().tabItem { Label("Screens", systemImage: "display.2") }
            LooksSettings().tabItem { Label("Looks", systemImage: "square.3.layers.3d") }
            ThemesSettings().tabItem { Label("Themes", systemImage: "paintpalette") }
            MacrosSettings().tabItem { Label("Macros", systemImage: "bolt") }
            StageSettings().tabItem { Label("Stage", systemImage: "person.wave.2") }
            PlanningCenterSettings().tabItem { Label("Planning Center", systemImage: "calendar") }
            BibleSettings().tabItem { Label("Bible", systemImage: "book.closed") }
            ConnectSettings().tabItem { Label("Remote & MIDI", systemImage: "iphone.radiowaves.left.and.right") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .scenePadding()
    }
}

// MARK: - Screens

struct ScreensSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selected: UUID?
    @State private var deckLinks: [String] = []

    var body: some View {
        @Bindable var store = app.store
        HSplitView {
            List(selection: $selected) {
                ForEach(store.data.screens) { s in
                    Label(s.name, systemImage: s.role == .stage ? "person.wave.2" : s.role == .stream ? "video" : "display")
                        .tag(s.id)
                }
                .onDelete { store.data.screens.remove(atOffsets: $0) }
            }
            .frame(minWidth: 180, maxWidth: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu("Add Screen") {
                        ForEach(ScreenRole.allCases) { r in
                            Button(r.title) {
                                var s = Screen(name: r.title, role: r)
                                if r == .stage { s.stageLayoutID = store.data.stageLayouts.first?.id }
                                store.data.screens.append(s)
                                selected = s.id
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Apply") { app.outputs.rebuild() }
                }
                .padding(8)
            }

            if let id = selected, store.data.screens.contains(where: { $0.id == id }) {
                ScreenDetail(screen: binding($store.data.screens, id, fallback: Screen(name: "", role: .audience)), deckLinks: deckLinks)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Screens").font(.title2.bold())
                    Text("Each screen is one picture Lumen renders — Audience (projectors/LEDs), Livestream (keyed or full), Stage (confidence monitor). Send a screen to any combination of Mac displays, DeckLink outputs and NDI.")
                    HardwareStatus()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { deckLinks = DeckLinkSink.deviceNames; selected = selected ?? store.data.screens.first?.id }
        .onDisappear { app.outputs.rebuildIfNeeded() }
    }
}

struct HardwareStatus: View {
    var body: some View {
        GroupBox("Hardware") {
            VStack(alignment: .leading, spacing: 6) {
                status("DeckLink SDK compiled in", LMDeckLinkOutput.sdkCompiledIn())
                status("Blackmagic Desktop Video driver", LMDeckLinkOutput.driverAvailable())
                ForEach(LMDeckLinkOutput.devices(), id: \.name) { d in
                    Text("• \(d.name)\(d.supportsExternalKeying ? " — fill+key capable" : "")").font(.caption)
                }
                status("NDI SDK compiled in", LMNDI.sdkCompiledIn())
                status("NDI runtime (NDI Tools)", LMNDI.runtimeAvailable())
                Text("Displays: " + NSScreen.screens.map(\.localizedName).joined(separator: ", ")).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func status(_ name: String, _ ok: Bool) -> some View {
        Label(name, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
    }
}

struct ScreenDetail: View {
    @Environment(AppModel.self) private var app
    @Binding var screen: Screen
    var deckLinks: [String]

    var body: some View {
        Form {
            TextField("Name", text: $screen.name)
            Picker("Role", selection: $screen.role) { ForEach(ScreenRole.allCases) { Text($0.title).tag($0) } }
            Toggle("Enabled", isOn: $screen.enabled)
            if screen.role == .stage {
                Picker("Stage layout", selection: $screen.stageLayoutID) {
                    ForEach(app.store.data.stageLayouts) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Section("Resolution (Mac displays / NDI)") {
                Picker("Size", selection: Binding(get: { "\(screen.width)x\(screen.height)" }, set: {
                    let p = $0.split(separator: "x").compactMap { Int($0) }; screen.width = p[0]; screen.height = p[1]
                })) {
                    Text("1920 × 1080").tag("1920x1080")
                    Text("1280 × 720").tag("1280x720")
                    Text("3840 × 2160").tag("3840x2160")
                }
                Picker("Frame rate", selection: $screen.fps) {
                    Text("29.97").tag(29.97); Text("30").tag(30.0); Text("59.94").tag(59.94); Text("60").tag(60.0); Text("25").tag(25.0)
                }
                Text("DeckLink outputs use their video mode's size and rate instead.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Send to") {
                ForEach(Array(screen.destinations.enumerated()), id: \.offset) { i, d in
                    DestinationRow(dest: Binding(get: { screen.destinations[safe: i] ?? d },
                                                 set: { if screen.destinations.indices.contains(i) { screen.destinations[i] = $0 } }),
                                   deckLinks: deckLinks) {
                        screen.destinations.remove(at: i)
                    }
                }
                Menu("Add Output") {
                    Menu("Mac Display") {
                        ForEach(NSScreen.screens, id: \.displayID) { s in
                            Button(s.localizedName + (s == NSScreen.main ? " (operator screen!)" : "")) {
                                screen.destinations.append(.display(id: s.displayID, name: s.localizedName))
                            }
                        }
                    }
                    Menu("DeckLink") {
                        if deckLinks.isEmpty { Text("No DeckLink outputs found") }
                        ForEach(deckLinks, id: \.self) { n in
                            Button(n) { screen.destinations.append(.decklink(device: n, mode: .hd1080p2997, keyer: screen.role == .stream)) }
                        }
                    }
                    Button("NDI") { screen.destinations.append(.ndi(name: "Lumen \(screen.name)")) }
                    Button("Floating Window (testing)") { screen.destinations.append(.window) }
                }
            }
            if let status = app.outputs.statusByScreen[screen.id], !status.isEmpty {
                Section("Status") { ForEach(status, id: \.self) { Text($0).font(.caption) } }
            }
            Button("Apply Output Changes") { app.outputs.rebuild() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }
}

struct DestinationRow: View {
    @Binding var dest: ScreenDestination
    var deckLinks: [String]
    var remove: () -> Void

    var body: some View {
        HStack {
            switch dest {
            case .decklink(let device, let mode, let keyer):
                VStack(alignment: .leading) {
                    Text("DeckLink: \(device)")
                    HStack {
                        Picker("Mode", selection: Binding(get: { mode }, set: { dest = .decklink(device: device, mode: $0, keyer: keyer) })) {
                            ForEach(VideoMode.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                        Toggle("Fill + Key", isOn: Binding(get: { keyer }, set: { dest = .decklink(device: device, mode: mode, keyer: $0) }))
                            .help("Outputs alpha as a key signal on the paired SDI connector for your switcher's downstream keyer")
                    }
                }
            case .ndi(let name):
                Text("NDI:")
                TextField("Source name", text: Binding(get: { name }, set: { dest = .ndi(name: $0) }))
            default:
                Text(dest.summary)
            }
            Spacer()
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }
}

// MARK: - Looks

struct LooksSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = app.store
        HSplitView {
            List(selection: $selected) {
                ForEach(store.data.looks) { l in Text(l.name).tag(l.id) }
                    .onDelete { store.data.looks.remove(atOffsets: $0) }
            }
            .frame(minWidth: 180, maxWidth: 220)
            .safeAreaInset(edge: .bottom) {
                Button("Add Look") {
                    let l = Look(name: "New Look")
                    store.data.looks.append(l)
                    selected = l.id
                }
                .padding(8)
            }
            if let id = selected, store.data.looks.contains(where: { $0.id == id }) {
                LookDetail(look: binding($store.data.looks, id, fallback: Look(name: "")))
            } else {
                Text("A Look decides what every screen shows. Example: “Service” sends full slides to the room and lyric/Bible lower thirds (transparent) to the livestream; “Stream Takeover” sends the full 1920×1080 slide to the stream.")
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { selected = selected ?? store.data.looks.first?.id }
    }
}

struct LookDetail: View {
    @Environment(AppModel.self) private var app
    @Binding var look: Look

    var body: some View {
        Form {
            TextField("Name", text: $look.name)
            ForEach(app.store.data.screens.filter { $0.role != .stage }) { screen in
                Section(screen.name) {
                    let cfg = Binding(get: { look.config(for: screen.id) }, set: { look.screens[screen.id] = $0 })
                    HStack {
                        Toggle("Media", isOn: cfg.layers.background)
                        Toggle("Slide", isOn: cfg.layers.slide)
                        Toggle("Props", isOn: cfg.layers.props)
                        Toggle("Messages", isOn: cfg.layers.messages)
                        Toggle("Live video", isOn: cfg.layers.liveVideo)
                    }
                    Picker("Slides show as", selection: cfg.defaultMode) {
                        ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
                    }
                    DisclosureGroup("Per slide type (e.g. Bible → Lower Third)") {
                        ForEach(PresentationKind.allCases) { kind in
                            HStack {
                                Label(kind.title, systemImage: kind.symbol).frame(width: 130, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { cfg.wrappedValue.modeByKind[kind] },
                                    set: { cfg.wrappedValue.modeByKind[kind] = $0 })) {
                                    Text("Same as default").tag(RenderMode?.none)
                                    ForEach(RenderMode.allCases) { Text($0.title).tag(Optional($0)) }
                                }
                                .labelsHidden()
                                Picker("", selection: Binding(
                                    get: { cfg.wrappedValue.themeByKind[kind] },
                                    set: { cfg.wrappedValue.themeByKind[kind] = $0 })) {
                                    Text("Slide's own theme").tag(UUID?.none)
                                    ForEach(app.store.data.themes) { Text($0.name).tag(Optional($0.id)) }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Themes

struct ThemesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = app.store
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.data.themes) { t in Text(t.name).tag(t.id) }
                        .onDelete { store.data.themes.remove(atOffsets: $0) }
                }
                Form {
                    Section("Default theme for each slide type") {
                        ForEach(PresentationKind.allCases) { kind in
                            Picker(kind.title, selection: Binding(
                                get: { store.data.settings.defaultThemeByKind[kind] },
                                set: { store.data.settings.defaultThemeByKind[kind] = $0 })) {
                                Text("—").tag(UUID?.none)
                                ForEach(store.data.themes) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: 260)
                HStack {
                    Button("Add") { let t = Theme(name: "New Theme"); store.data.themes.append(t); selected = t.id }
                    Button("Duplicate") {
                        if let id = selected, var t = store.theme(id) { t.id = UUID(); t.name += " copy"; store.data.themes.append(t); selected = t.id }
                    }
                    .disabled(selected == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 240, maxWidth: 300)
            if let id = selected, store.data.themes.contains(where: { $0.id == id }) {
                ScrollView { ThemeEditor(theme: binding($store.data.themes, id, fallback: Theme(name: ""))).padding() }
            } else {
                Text("Select a theme").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selected = selected ?? store.data.themes.first?.id }
    }
}

// MARK: - Macros

struct MacrosSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = app.store
        HSplitView {
            List(selection: $selected) {
                ForEach(store.data.macros) { m in Label(m.name, systemImage: m.symbol).foregroundStyle(m.color.color).tag(m.id) }
                    .onMove { store.data.macros.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { store.data.macros.remove(atOffsets: $0) }
            }
            .frame(minWidth: 180, maxWidth: 240)
            .safeAreaInset(edge: .bottom) {
                Button("Add Macro") { let m = Macro(name: "New Macro"); store.data.macros.append(m); selected = m.id }.padding(8)
            }
            if let id = selected, store.data.macros.contains(where: { $0.id == id }) {
                let m = binding($store.data.macros, id, fallback: Macro(name: ""))
                VStack(alignment: .leading) {
                    Form {
                        TextField("Name", text: m.name)
                        ColorPicker("Color", selection: ColorBinding.make(m.color))
                        TextField("SF Symbol", text: m.symbol)
                        Toggle("Show in volunteer mode", isOn: m.volunteerVisible)
                    }
                    .formStyle(.grouped).frame(height: 220)
                    ActionListEditor(actions: m.actions)
                    HStack {
                        Spacer()
                        Button("Test Macro") { app.engine.runMacro(id) }
                    }
                }
                .padding()
            } else {
                Text("Macros run several actions at once — set a look, start a timer, show a lower third, send MIDI to Lightkey, trigger a slide…")
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { selected = selected ?? store.data.macros.first?.id }
    }
}

// MARK: - Stage

struct StageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = app.store
        HSplitView {
            List(selection: $selected) {
                ForEach(store.data.stageLayouts) { Text($0.name).tag($0.id) }
                    .onDelete { store.data.stageLayouts.remove(atOffsets: $0) }
            }
            .frame(minWidth: 180, maxWidth: 220)
            .safeAreaInset(edge: .bottom) {
                Button("Add Layout") { let l = StageLayout(name: "New Layout"); store.data.stageLayouts.append(l); selected = l.id }.padding(8)
            }
            if let id = selected, store.data.stageLayouts.contains(where: { $0.id == id }) {
                let l = binding($store.data.stageLayouts, id, fallback: StageLayout(name: ""))
                Form {
                    TextField("Name", text: l.name)
                    Toggle("Current slide", isOn: l.showCurrent)
                    Toggle("Next slide", isOn: l.showNext)
                    Toggle("Clock", isOn: l.showClock)
                    Toggle("Slide notes", isOn: l.showNotes)
                    Toggle("Stage messages", isOn: l.showMessage)
                    Slider(value: l.textScale, in: 0.6...1.6) { Text("Text size") }
                    ColorPicker("Current color", selection: ColorBinding.make(l.currentColor))
                    ColorPicker("Next color", selection: ColorBinding.make(l.nextColor))
                    Section("Chords") {
                        Toggle("Show chords above lyrics", isOn: Binding(get: { l.wrappedValue.showChords != false },
                                                                         set: { l.wrappedValue.showChords = $0 }))
                        Picker("Style", selection: Binding(get: { l.wrappedValue.chordStyle ?? .nashville },
                                                           set: { l.wrappedValue.chordStyle = $0 })) {
                            ForEach(ChordStyle.allCases) { Text($0.title).tag($0) }
                        }
                        ColorPicker("Chord color", selection: Binding(
                            get: { (l.wrappedValue.chordColor ?? RGBA(hex: "#38BDF8")).color },
                            set: { l.wrappedValue.chordColor = RGBA($0) }))
                        Text("Songs show chords once a chord chart is imported (song → Chords). Nashville numbers are counted from the song's key, so they stay right even if the band changes keys.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Timers shown") {
                        ForEach(store.data.timers) { t in
                            Toggle(t.name, isOn: Binding(
                                get: { l.wrappedValue.timerIDs.contains(t.id) },
                                set: { on in if on { l.wrappedValue.timerIDs.append(t.id) } else { l.wrappedValue.timerIDs.removeAll { $0 == t.id } } }))
                        }
                    }
                    Section {
                        Text("Phones and tablets can also show the stage display: open \(app.remote.urls.first ?? "http://<this-mac>:\(store.data.settings.remotePort)")/stage")
                            .font(.caption).textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onAppear { selected = selected ?? store.data.stageLayouts.first?.id }
    }
}

// MARK: - Planning Center

struct PlanningCenterSettings: View {
    @Environment(AppModel.self) private var app
    @State private var secret = Keychain.get("pco-secret")
    @State private var serviceTypes: [(id: String, name: String)] = []
    @State private var error: String?

    var body: some View {
        @Bindable var store = app.store
        Form {
            Section {
                TextField("Application ID", text: $store.data.settings.pcoAppID)
                SecureField("Secret", text: $secret).onSubmit { Keychain.set("pco-secret", secret) }
                HStack {
                    Button("Connect & Load Service Types") {
                        Keychain.set("pco-secret", secret)
                        Task {
                            do { serviceTypes = try await app.pco.client.serviceTypes(); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    Link("Create a Personal Access Token", destination: URL(string: "https://api.planningcenteronline.com/oauth/applications")!)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            } header: { Text("Account") } footer: {
                Text("The secret is stored in your Mac's Keychain.")
            }

            if !serviceTypes.isEmpty || !store.data.settings.pcoServiceTypeIDs.isEmpty {
                Section("Service types to sync") {
                    ForEach(serviceTypes, id: \.id) { st in
                        Toggle(st.name, isOn: Binding(
                            get: { store.data.settings.pcoServiceTypeIDs.contains(st.id) },
                            set: { on in
                                if on { store.data.settings.pcoServiceTypeIDs.append(st.id) }
                                else { store.data.settings.pcoServiceTypeIDs.removeAll { $0 == st.id } }
                            }))
                    }
                    if serviceTypes.isEmpty { Text("\(store.data.settings.pcoServiceTypeIDs.count) selected") }
                }
            }

            Section("Sync") {
                Stepper("Look ahead \(store.data.settings.pcoSyncDaysAhead) days", value: $store.data.settings.pcoSyncDaysAhead, in: 7...120, step: 7)
                Stepper("Auto-sync every \(store.data.settings.pcoAutoSyncMinutes) min (0 = off)", value: $store.data.settings.pcoAutoSyncMinutes, in: 0...120, step: 5)
                    .onChange(of: store.data.settings.pcoAutoSyncMinutes) { _, _ in app.pco.startAutoSync() }
                HStack {
                    Button(app.pco.isSyncing ? "Syncing…" : "Sync Now") { Task { await app.pco.sync() } }.disabled(app.pco.isSyncing)
                    if let d = app.pco.lastSync { Text("Last sync \(d.formatted())").font(.caption).foregroundStyle(.secondary) }
                }
                if let e = app.pco.lastError { Text(e).foregroundStyle(.red).font(.caption) }
            }

            Section {
                Picker("Template", selection: $store.data.settings.pcoTemplateID) {
                    ForEach(store.data.templates) { Text($0.name).tag(Optional($0.id)) }
                }
                if let id = store.data.settings.pcoTemplateID, store.data.templates.contains(where: { $0.id == id }) {
                    TemplateEditor(template: binding($store.data.templates, id, fallback: ServiceTemplate(name: "")))
                }
            } header: { Text("Service template") } footer: {
                Text("Rules run top to bottom for every plan item. Songs pull lyrics + arrangement sequence from Planning Center (CCLI SongSelect-sourced). Items titled like “Scripture: John 3:16” become Bible slides automatically.")
            }

            if !app.pco.log.isEmpty {
                Section("Activity") {
                    ForEach(Array(app.pco.log.suffix(12).reversed().enumerated()), id: \.offset) { _, l in Text(l).font(.caption) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct TemplateEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var template: ServiceTemplate

    var body: some View {
        TextField("Template name", text: $template.name)
        ForEach($template.rules) { $rule in
            HStack {
                Picker("", selection: $rule.match) {
                    Text("Song").tag(TemplateMatch.song)
                    Text("Header").tag(TemplateMatch.header)
                    Text("Media").tag(TemplateMatch.media)
                    Text("Title contains").tag(TemplateMatch.titleContains)
                }
                .labelsHidden().frame(width: 130)
                if rule.match == .titleContains { TextField("text", text: $rule.text).frame(width: 120) }
                Image(systemName: "arrow.right")
                Picker("", selection: $rule.result) {
                    Text("Song lyrics").tag(TemplateResult.songLyrics)
                    Text("Scripture slides").tag(TemplateResult.scripture)
                    Text("Header").tag(TemplateResult.header)
                    Text("Placeholder").tag(TemplateResult.placeholder)
                    Text("Skip").tag(TemplateResult.skip)
                    ForEach(app.store.data.presentations.filter { $0.kind != .song && $0.kind != .scripture }) { p in
                        Text("“\(p.name)”").tag(TemplateResult.presentationNamed(p.name))
                    }
                    if case .presentationNamed(let n) = rule.result,
                       !app.store.data.presentations.contains(where: { $0.name == n && $0.kind != .song && $0.kind != .scripture }) {
                        Text("“\(n)” (created on sync)").tag(rule.result)
                    }
                }
                .labelsHidden()
                Button {
                    template.rules.removeAll { $0.id == rule.id }
                } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
        }
        Button("Add Rule") { template.rules.append(TemplateRule(match: .titleContains, text: "", result: .placeholder)) }
        Picker("Always start with", selection: Binding(get: { template.leadingPresentations.first }, set: { template.leadingPresentations = [$0].compactMap { $0 } })) {
            Text("Nothing").tag(UUID?.none)
            ForEach(app.store.data.presentations) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}

// MARK: - Bible

struct BibleSettings: View {
    @Environment(AppModel.self) private var app
    @State private var apiBibleKey = Keychain.get("apibible-key")
    @State private var esvKey = Keychain.get("esv-key")
    @State private var importAbbr = ""
    @State private var message: String?

    var body: some View {
        @Bindable var store = app.store
        Form {
            Picker("Source", selection: $store.data.settings.bibleProvider) {
                ForEach(BibleProviderKind.allCases) { Text($0.title).tag($0) }
            }
            Section("API.Bible") {
                SecureField("API key", text: $apiBibleKey).onSubmit { Keychain.set("apibible-key", apiBibleKey) }
                Link("Get a free key at scripture.api.bible", destination: URL(string: "https://scripture.api.bible")!)
                Text("Includes NASB, CSB, NKJV*, AMP, Spanish, and thousands more depending on what your key is licensed for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ESV") {
                SecureField("ESV API key", text: $esvKey).onSubmit { Keychain.set("esv-key", esvKey) }
                Link("Get a key at api.esv.org", destination: URL(string: "https://api.esv.org")!)
            }
            Section("Import a Bible file") {
                Text("Any translation your church is licensed to display (NIV, NLT, etc.) can be imported from a Zefania or OSIS XML file.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Abbreviation (e.g. NIV)", text: $importAbbr).frame(width: 180)
                    Button("Choose XML…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.xml]
                        guard panel.runModal() == .OK, let u = panel.url else { return }
                        do {
                            let t = try app.scripture.local.importXML(at: u, abbreviation: importAbbr)
                            store.data.settings.bibleProvider = .local
                            store.data.settings.bibleTranslation = t.id
                            message = "Imported \(t.name)"
                        } catch { message = error.localizedDescription }
                    }
                }
                if let message { Text(message).font(.caption) }
            }
            Section("Slides") {
                Stepper("Verses per slide: \(store.data.settings.bibleVersesPerSlide)", value: $store.data.settings.bibleVersesPerSlide, in: 1...8)
                Stepper("Max characters per slide: \(store.data.settings.bibleMaxCharsPerSlide)", value: $store.data.settings.bibleMaxCharsPerSlide, in: 80...800, step: 20)
                Text("Scripture slides use the theme set for “Scripture” in Themes, and Looks can put them in a Bible lower third on the stream automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            Keychain.set("apibible-key", apiBibleKey)
            Keychain.set("esv-key", esvKey)
        }
    }
}

// MARK: - Remote & MIDI

struct ConnectSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var store = app.store
        Form {
            Section("Remote control") {
                Toggle("Allow phones, tablets and computers to control Lumen", isOn: $store.data.settings.remoteEnabled)
                    .onChange(of: store.data.settings.remoteEnabled) { _, on in
                        on ? app.remote.start(port: store.data.settings.remotePort) : app.remote.stop()
                    }
                Stepper("Port \(store.data.settings.remotePort)", value: $store.data.settings.remotePort, in: 1024...65000)
                TextField("PIN (blank = none)", text: $store.data.settings.remotePIN)
                Button("Restart Server") { app.remote.start(port: store.data.settings.remotePort) }
                if let e = app.remote.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                ForEach(app.remote.urls, id: \.self) { u in
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = QRCode.image(u) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 110, height: 110)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Remote: \(u)").textSelection(.enabled).font(.body.monospaced())
                            Text("Stage display: \(u)/stage").textSelection(.enabled).font(.body.monospaced())
                            Text("Scan with a phone on the same Wi-Fi, or type the address into any browser.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Toggle("Enable MIDI", isOn: $store.data.settings.midiEnabled)
                TextField("Virtual port name", text: $store.data.settings.midiOutputName)
                Text(app.midi.isReady ? "“\(store.data.settings.midiOutputName)” is available as a MIDI source and destination." : "MIDI is off.")
                    .font(.caption)
                if !app.midi.lastSent.isEmpty { Text("Last sent: \(app.midi.lastSent)").font(.caption) }
                if !app.midi.lastReceived.isEmpty { Text("Last received: \(app.midi.lastReceived)").font(.caption) }
                Button("Send Test Note (C4)") { app.midi.send(MIDIMessage(kind: .noteOn, channel: 1, number: 60, value: 127)) }
            } header: { Text("MIDI (Lightkey)") } footer: {
                Text("In Lightkey: Preferences → MIDI → enable input from “\(store.data.settings.midiOutputName)”, then MIDI-learn a cue by pressing Send Test Note. Add “Send MIDI” to macros or slide actions to fire Lightkey cues.")
            }
            Section("Incoming MIDI → actions") {
                ForEach($store.data.midiMappings) { $m in
                    HStack {
                        Text(m.message.summary)
                        Spacer()
                        Text(m.actions.map(\.summary).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDelete { store.data.midiMappings.remove(atOffsets: $0) }
                Menu("Map last received message to macro") {
                    ForEach(store.data.macros) { mac in
                        Button(mac.name) {
                            guard let msg = lastReceivedMessage else { return }
                            store.data.midiMappings.append(MIDIMapping(message: msg, actions: [.triggerMacro(mac.id)]))
                        }
                    }
                }
                .disabled(app.midi.lastReceived.isEmpty)
                Menu("Map note to Next/Previous") {
                    Button("Note 60 → Next") { store.data.midiMappings.append(MIDIMapping(message: MIDIMessage(kind: .noteOn, channel: 1, number: 60), actions: [.nextSlide])) }
                    Button("Note 59 → Previous") { store.data.midiMappings.append(MIDIMapping(message: MIDIMessage(kind: .noteOn, channel: 1, number: 59), actions: [.previousSlide])) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastReceivedMessage: MIDIMessage? {
        // Parse back the summary of the last message ("Note On ch1 #60 v127").
        let s = app.midi.lastReceived
        let nums = s.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        guard nums.count >= 2 else { return nil }
        let kind: MIDIMessage.Kind = s.hasPrefix("CC") ? .controlChange : s.hasPrefix("Program") ? .programChange : s.hasPrefix("Note Off") ? .noteOff : .noteOn
        return MIDIMessage(kind: kind, channel: nums[0], number: nums[1], value: nums[safe: 2] ?? 127)
    }
}

enum QRCode {
    static func image(_ string: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(string.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var calendars: [String] = []

    var body: some View {
        @Bindable var store = app.store
        Form {
            Section("Volunteer mode") {
                TextField("Exit PIN", text: $store.data.settings.volunteerPIN)
                Toggle("Start in volunteer mode", isOn: $store.data.settings.startInVolunteerMode)
            }
            Section("Transitions") {
                Slider(value: $store.data.settings.transitionSeconds, in: 0...2) {
                    Text("Slide dissolve \(String(format: "%.2f", store.data.settings.transitionSeconds))s")
                }
            }
            Section("Listening") {
                Picker("Language", selection: $store.data.settings.speechLocale) {
                    ForEach(["en-US", "en-GB", "en-AU", "es-US", "es-MX", "pt-BR", "fr-FR", "de-DE", "ko-KR"], id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                Toggle("Fire actions from calendar events", isOn: $store.data.settings.calendarTriggersEnabled)
                    .onChange(of: store.data.settings.calendarTriggersEnabled) { _, on in
                        if on { Task { await app.scheduler.requestCalendar(); loadCalendars() } }
                    }
                Picker("Calendar", selection: $store.data.settings.calendarName) {
                    Text("All calendars").tag("")
                    ForEach(calendars, id: \.self) { Text($0).tag($0) }
                }
            } header: { Text("Calendar") } footer: {
                Text("Add lines like “lumen: macro Walk In”, “lumen: slide Announcements 2”, “lumen: look Stream Takeover” or “lumen: timer Service Countdown” to an event's notes. They run when the event starts.")
            }
            Section("Library") {
                Text(app.store.folder.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.store.folder]) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadCalendars)
    }

    private func loadCalendars() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        calendars = EKEventStore().calendars(for: .event).map(\.title).sorted()
    }
}
