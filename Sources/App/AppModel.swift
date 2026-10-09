import AppKit
import Observation
import SwiftUI

/// Owns every subsystem and wires them together.
@MainActor
@Observable
final class AppModel {
    let store: LibraryStore
    let engine: LiveEngine
    let outputs: OutputManager
    let media: MediaEngine
    let capture: CaptureManager
    let browser: BrowserController
    let ndiIn: NDIReceiveManager
    let midi: MIDIManager
    let scripture: ScriptureService
    let pco: PlanningCenterSync
    let remote: RemoteServer
    let scheduler: Scheduler
    let listening: ListeningService
    let updates: UpdateManager

    // UI state
    var selectedPresentationID: UUID?
    var selectedPlaylistID: UUID?
    var volunteerMode = false
    var toast: String?
    var showScreensEditor = false
    var editingPresentationID: UUID?
    /// Which tab the presentation editor opens on (4 = Chords).
    var editorInitialMode = 0

    init() {
        let store = LibraryStore()
        self.store = store
        engine = LiveEngine(store: store)
        outputs = OutputManager(store: store, engine: engine)
        media = MediaEngine()
        capture = CaptureManager()
        browser = BrowserController()
        ndiIn = NDIReceiveManager()
        midi = MIDIManager()
        scripture = ScriptureService(store: store)
        pco = PlanningCenterSync(store: store, scripture: scripture)
        remote = RemoteServer()
        scheduler = Scheduler(store: store, engine: engine)
        listening = ListeningService()
        updates = UpdateManager()

        engine.media = media
        engine.capture = capture
        engine.browser = browser
        engine.ndiIn = ndiIn
        engine.midi = midi
        engine.onChange = { [weak self] in self?.outputs.update() }
        remote.app = self
        updates.app = self
        listening.engine = engine
        listening.settings = { [weak store] in store?.data.settings ?? AppSettings() }

        volunteerMode = store.data.settings.startInVolunteerMode
        selectedPlaylistID = store.data.playlists.first?.id

        midi.onMessage = { [weak self] msg in self?.handleMIDI(msg) }
    }

    func start() {
        outputs.rebuild()
        if store.data.settings.midiEnabled { midi.start(name: store.data.settings.midiOutputName) }
        if store.data.settings.remoteEnabled { remote.start(port: store.data.settings.remotePort) }
        scheduler.start()
        pco.startAutoSync()
        updates.checkAtLaunch()
        if pco.isConfigured { Task { await pco.sync() } }
    }

    func shutdown() {
        store.saveNow()
        outputs.renderers.values.forEach { $0.stop() }
        listening.stop()
    }

    private func handleMIDI(_ msg: MIDIMessage) {
        for m in store.data.midiMappings where m.message.kind == msg.kind && m.message.channel == msg.channel
            && m.message.number == msg.number {
            Task { await engine.perform(m.actions) }
        }
    }

    func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }

    // MARK: Convenience

    var selectedPresentation: Presentation? { engine.presentation(selectedPresentationID) }

    func newPresentation(kind: PresentationKind, name: String? = nil) -> Presentation {
        var p = Presentation(name: name ?? "New \(kind.title)", kind: kind)
        p.groups = [SlideGroup(name: kind == .song ? "Verse 1" : "Slides", color: SlideGroup.color(for: "Verse"),
                               slides: [Slide(text: "")])]
        store.upsert(p)
        selectedPresentationID = p.id
        return p
    }

    func addToSelectedPlaylist(_ id: UUID) {
        guard let plID = selectedPlaylistID, let i = store.data.playlists.firstIndex(where: { $0.id == plID }) else { return }
        store.data.playlists[i].items.append(PlaylistItem(kind: .presentation(id)))
    }

    /// Saves a transient (e.g. scripture) presentation into the library.
    func keep(_ p: Presentation) {
        store.upsert(p)
    }
}
