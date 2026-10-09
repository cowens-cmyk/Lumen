import SwiftUI

/// A calm, big-button view for volunteers: today's playlist, slides, next/back, clear.
/// Looks, themes, outputs and setup are hidden; leaving needs the PIN.
struct VolunteerView: View {
    @Environment(AppModel.self) private var app
    @State private var askPIN = false
    @State private var pin = ""

    private var playlist: Playlist? {
        let d = app.store.data
        if let id = app.selectedPlaylistID, let p = d.playlists.first(where: { $0.id == id }) { return p }
        // Default to the next upcoming service.
        return d.playlists.filter { ($0.date ?? .distantFuture) > Date().addingTimeInterval(-86400) }
            .min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) } ?? d.playlists.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(playlist?.name ?? "No service loaded").font(.title2.bold())
                Spacer()
                if app.listening.isListening && app.listening.followLyrics {
                    ConfidenceView(confidence: app.listening.confidence, status: app.listening.status, active: true).frame(width: 220)
                    Button("I've got it") { app.listening.takeOver() }.controlSize(.large)
                }
                Button { askPIN = true } label: { Label("Exit", systemImage: "lock") }
            }
            .padding()
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding(get: { app.selectedPresentationID }, set: { app.selectedPresentationID = $0 })) {
                    ForEach(playlist?.items ?? []) { item in
                        PlaylistRow(item: item)
                            .font(.title3)
                            .padding(.vertical, 4)
                            .tag({ if case .presentation(let id) = item.kind { id } else { nil } }() as UUID?)
                    }
                }
                .frame(width: 300)
                Divider()
                SlideGrid()
            }
            Divider()
            HStack(spacing: 14) {
                Button { app.engine.previous() } label: {
                    Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity, minHeight: 44)
                }
                Button { app.engine.next() } label: {
                    Label("Next", systemImage: "chevron.right").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button { app.engine.clear(.slide) } label: { Text("Clear Words").frame(minHeight: 44) }
                Button { app.engine.clear(.all) } label: { Text("Clear Everything").frame(minHeight: 44) }.tint(.red)
                ForEach(app.store.data.macros.filter(\.volunteerVisible)) { m in
                    Button { app.engine.runMacro(m.id) } label: { Label(m.name, systemImage: m.symbol).frame(minHeight: 44) }
                        .tint(m.color.color)
                }
            }
            .controlSize(.large)
            .font(.title3)
            .padding()
        }
        .onAppear {
            if app.selectedPlaylistID == nil { app.selectedPlaylistID = playlist?.id }
        }
        .alert("Enter PIN to exit volunteer mode", isPresented: $askPIN) {
            SecureField("PIN", text: $pin)
            Button("Exit") {
                if pin == app.store.data.settings.volunteerPIN { app.volunteerMode = false }
                pin = ""
            }
            Button("Cancel", role: .cancel) { pin = "" }
        }
    }
}
