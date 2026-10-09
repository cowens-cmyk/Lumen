import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Binding var importing: Bool
    @Binding var pasteLyrics: Bool
    @State private var tab = 0
    @State private var search = ""
    @State private var renamingPlaylist: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Playlists").tag(0)
                Text("Library").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Group {
                if tab == 0 { playlists } else { library }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                Menu {
                    Button("New Song…") { pasteLyrics = true }
                    Button("New Blank Song") { _ = app.newPresentation(kind: .song) }
                    Button("New Presentation") { _ = app.newPresentation(kind: .generic) }
                    Button("New Sermon") { _ = app.newPresentation(kind: .sermon) }
                    Button("New Announcement") { _ = app.newPresentation(kind: .announcement) }
                    Divider()
                    Button("New Playlist") {
                        let pl = Playlist(name: "New Playlist", date: Date())
                        app.store.upsert(pl)
                        app.selectedPlaylistID = pl.id
                        tab = 0
                    }
                    Divider()
                    Button("Import Files…  (images, video, PDF, PowerPoint, Keynote, lyrics)") { importing = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                PCOStatus()
            }
            .padding(8)
        }
    }

    // MARK: Playlists

    private var sortedPlaylists: [Playlist] {
        app.store.data.playlists.sorted { ($0.date ?? .distantFuture, $0.name) < ($1.date ?? .distantFuture, $1.name) }
    }

    private var playlists: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            Picker("Playlist", selection: $app.selectedPlaylistID) {
                Text("Choose a playlist").tag(UUID?.none)
                ForEach(sortedPlaylists) { pl in
                    Text((pl.syncLocked == true ? "🔒 " : pl.pcoPlanID != nil ? "⟳ " : "") + pl.name).tag(Optional(pl.id))
                }
            }
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            if let id = app.selectedPlaylistID, let pl = app.store.data.playlists.first(where: { $0.id == id }) {
                List(selection: Binding(get: { app.selectedPresentationID }, set: { app.selectedPresentationID = $0 })) {
                    ForEach(pl.items) { item in
                        PlaylistRow(item: item)
                            .tag(presentationID(item))
                            .contextMenu {
                                Button("Remove from Playlist", role: .destructive) { remove(item, from: pl.id) }
                            }
                    }
                    .onMove { from, to in
                        guard let i = app.store.data.playlists.firstIndex(where: { $0.id == pl.id }) else { return }
                        app.store.data.playlists[i].items.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.sidebar)
                .dropDestination(for: String.self) { ids, _ in
                    guard let i = app.store.data.playlists.firstIndex(where: { $0.id == pl.id }) else { return false }
                    for s in ids { if let u = UUID(uuidString: s) { app.store.data.playlists[i].items.append(PlaylistItem(kind: .presentation(u))) } }
                    return true
                }
                HStack {
                    if pl.pcoPlanID != nil {
                        Label("Synced from Planning Center", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Add Header") {
                            if let i = app.store.data.playlists.firstIndex(where: { $0.id == pl.id }) {
                                app.store.data.playlists[i].items.append(PlaylistItem(kind: .header("Header")))
                            }
                        }
                        Button(pl.syncLocked == true ? "Unlock (allow Planning Center updates)" : "Lock (ignore Planning Center updates)") {
                            if let i = app.store.data.playlists.firstIndex(where: { $0.id == pl.id }) {
                                app.store.data.playlists[i].syncLocked = pl.syncLocked == true ? nil : true
                            }
                        }
                        Button("Rename…") { renamingPlaylist = pl.id }
                        Button("Delete Playlist…", role: .destructive) {
                            let a = NSAlert()
                            a.messageText = "Delete the playlist “\(pl.name)”?"
                            a.informativeText = "The songs themselves stay in the library."
                            a.alertStyle = .warning
                            a.addButton(withTitle: "Cancel")
                            a.addButton(withTitle: "Delete")
                            guard a.runModal() == .alertSecondButtonReturn else { return }
                            app.store.data.playlists.removeAll { $0.id == pl.id }
                            app.selectedPlaylistID = sortedPlaylists.first?.id
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.horizontal, 8)
            } else {
                ContentUnavailableView("No Playlist", systemImage: "list.bullet.rectangle",
                                       description: Text("Create one with + or sync from Planning Center."))
            }
        }
        .sheet(item: Binding(get: { renamingPlaylist.map(IDBox.init) }, set: { renamingPlaylist = $0?.id })) { box in
            RenamePlaylist(id: box.id)
        }
    }

    private func presentationID(_ item: PlaylistItem) -> UUID? {
        if case .presentation(let id) = item.kind { return id }
        return nil
    }

    private func remove(_ item: PlaylistItem, from plID: UUID) {
        guard let i = app.store.data.playlists.firstIndex(where: { $0.id == plID }) else { return }
        app.store.data.playlists[i].items.removeAll { $0.id == item.id }
    }

    // MARK: Library

    private var library: some View {
        VStack(spacing: 0) {
            TextField("Search songs, scripture, media…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8).padding(.bottom, 6)
            List(selection: Binding(get: { app.selectedPresentationID }, set: { app.selectedPresentationID = $0 })) {
                ForEach(PresentationKind.allCases) { kind in
                    let items = app.store.data.presentations
                        .filter { $0.kind == kind && matches($0) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if !items.isEmpty {
                        Section(kind.title + "s") {
                            ForEach(items) { p in
                                Label(p.name, systemImage: kind.symbol)
                                    .tag(Optional(p.id))
                                    .draggable(p.id.uuidString)
                                    .contextMenu { libraryMenu(p) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func confirmDelete(_ p: Presentation) {
        let e = app.engine
        let a = NSAlert()
        if e.livePresentationID == p.id, !e.slideCleared {
            a.messageText = "“\(p.name)” is on screen right now"
            a.informativeText = "Clear the outputs first, then delete it."
            a.addButton(withTitle: "OK")
            a.runModal(); return
        }
        a.messageText = "Delete “\(p.name)”?"
        a.informativeText = "It's removed from the library and from every playlist. This can't be undone (a copy of your library from earlier today is kept in the Backups folder)."
        a.alertStyle = .warning
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Delete")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        app.store.data.presentations.removeAll { $0.id == p.id }
        for i in app.store.data.playlists.indices {
            app.store.data.playlists[i].items.removeAll { if case .presentation(let id) = $0.kind { id == p.id } else { false } }
        }
    }

    private func matches(_ p: Presentation) -> Bool {
        guard !search.isEmpty else { return true }
        if p.name.localizedCaseInsensitiveContains(search) { return true }
        // Search inside lyrics too ("which song says 'goodness of God'?").
        return p.groups.contains { $0.slides.contains { $0.text.localizedCaseInsensitiveContains(search) } }
    }

    @ViewBuilder private func libraryMenu(_ p: Presentation) -> some View {
        Button("Edit…") { app.editingPresentationID = p.id }
        if p.kind == .song {
            Button("Chords & Nashville Numbers…") { app.editorInitialMode = 4; app.editingPresentationID = p.id }
        }
        Button("Add to Current Playlist") { app.addToSelectedPlaylist(p.id) }.disabled(app.selectedPlaylistID == nil)
        Button("Duplicate") {
            var c = p; c.id = UUID(); c.name += " copy"; c.pcoArrangementID = nil; c.pcoSongID = nil
            app.store.upsert(c)
        }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete(p) }
    }
}

struct PlaylistRow: View {
    @Environment(AppModel.self) private var app
    var item: PlaylistItem

    var body: some View {
        switch item.kind {
        case .header(let t):
            Text(t.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
        case .placeholder(let t):
            Label(t, systemImage: "questionmark.square.dashed").foregroundStyle(.secondary).italic()
        case .presentation(let id):
            let p = app.engine.presentation(id)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Label(p?.name ?? "Missing presentation", systemImage: p?.kind.symbol ?? "exclamationmark.triangle")
                    if let n = item.note { Text(n.components(separatedBy: "\n").first ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if app.engine.livePresentationID == id, !app.engine.slideCleared {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
            }
        }
    }
}

struct RenamePlaylist: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var id: UUID
    @State private var name = ""

    var body: some View {
        VStack {
            TextField("Name", text: $name).onAppear { name = app.store.data.playlists.first { $0.id == id }?.name ?? "" }
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    if let i = app.store.data.playlists.firstIndex(where: { $0.id == id }) { app.store.data.playlists[i].name = name }
                    dismiss()
                }.keyboardShortcut(.defaultAction) }
        }
        .padding().frame(width: 320)
    }
}

struct PCOStatus: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.pco.isSyncing {
            ProgressView().controlSize(.small)
        } else if let e = app.pco.lastError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
        } else if let d = app.pco.lastSync {
            Text("PCO \(d.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
