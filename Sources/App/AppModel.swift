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
    /// Set at launch when the last session ended badly with something live; the UI offers to put it back.
    var recovery: SessionSnapshot?
    /// Set right before a deliberate quit (the updater's relaunch) so the "something is live" prompt doesn't block it.
    var quitApproved = false
    @ObservationIgnored private var lastSession: SessionSnapshot?

    init(libraryFolder: URL = LibraryStore.defaultFolder) {
        let store = LibraryStore(folder: libraryFolder)
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
        engine.onChange = { [weak self] in
            self?.outputs.update()
            self?.noteSession()
        }
        remote.app = self
        updates.app = self
        pco.isLive = { [weak self] in
            guard let e = self?.engine else { return false }
            return (e.livePresentationID != nil && !e.slideCleared) || e.mediaLayer != nil
        }
        listening.engine = engine
        listening.settings = { [weak store] in store?.data.settings ?? AppSettings() }

        // Did the last run end badly with something live? Offer to restore it. Then mark this run as unclean until it quits properly.
        if let previous = SessionSnapshot.load(from: store.folder), previous.isRecoverable(),
           let id = previous.presentationID, store.presentation(id) != nil {
            recovery = previous
        }
        SessionSnapshot(cleanExit: false, savedAt: Date()).save(to: store.folder)

        volunteerMode = store.data.settings.startInVolunteerMode
        selectedPlaylistID = store.data.playlists.first?.id

        midi.onMessage = { [weak self] msg in self?.handleMIDI(msg) }
        engine.onProblem = { [weak self] text in self?.flash(text) }
    }

    @ObservationIgnored private var awakeActivity: NSObjectProtocol?

    /// A Mac that sleeps, or a display that dims, during a service is the worst case. Hold the whole system awake
    /// (and exempt Lumen from App Nap) for as long as it's running.
    func holdAwake(_ on: Bool) {
        if on, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
                reason: "Lumen is running a live presentation")
        } else if !on, let a = awakeActivity {
            ProcessInfo.processInfo.endActivity(a)
            awakeActivity = nil
        }
    }

    static var keepAwakeEnabled: Bool { UserDefaults.standard.object(forKey: "keepMacAwake") as? Bool ?? true }

    func start() {
        holdAwake(Self.keepAwakeEnabled)
        if store.data.settings.volunteerPIN.isEmpty || store.data.settings.volunteerPIN == "1234" {
            // "1234" is the first thing any volunteer would try. Pick a PIN once and show it where it can be changed.
            store.data.settings.volunteerPIN = String(format: "%04d", Int.random(in: 0...9999))
            flash("Volunteer-mode exit PIN is \(store.data.settings.volunteerPIN) — change it in Setup → General")
        }
        if store.data.settings.remotePIN.isEmpty {
            // The remote shares the church network with the congregation: never ship it open.
            store.data.settings.remotePIN = String(format: "%04d", Int.random(in: 0...9999))
            flash("Phone remote PIN is \(store.data.settings.remotePIN) — see Setup → Remote & MIDI")
        }
        outputs.rebuild()
        if let notice = store.loadNotice { flash(notice) }
        if let restored = store.restoredFromBackup { flash("Your library file was damaged; restored from backup \(restored)") }
        if store.data.settings.midiEnabled { midi.start(name: store.data.settings.midiOutputName) }
        if store.data.settings.remoteEnabled { remote.start(port: store.data.settings.remotePort) }
        scheduler.start()
        pco.startAutoSync()
        updates.checkAtLaunch()
        if pco.isConfigured { Task { await pco.sync() } }
    }

    /// Outputs off blanks every projector and the stream in one click, so it asks first.
    func toggleOutputs() {
        if outputs.outputsEnabled {
            let a = NSAlert()
            a.messageText = "Turn off all outputs?"
            a.informativeText = "Projectors, the livestream and the stage display will go dark until you turn them back on."
            a.alertStyle = .warning
            a.addButton(withTitle: "Keep Outputs On")
            a.addButton(withTitle: "Turn Off")
            guard a.runModal() == .alertSecondButtonReturn else { return }
        }
        outputs.outputsEnabled.toggle()
    }

    /// Records what's live whenever it changes (not on every clock tick).
    private func noteSession() {
        let e = engine
        let live = !e.slideCleared ? e.livePresentationID : nil
        let snap = SessionSnapshot(cleanExit: false, presentationID: live,
                                   presentationName: live.flatMap { e.presentation($0)?.name },
                                   index: live == nil ? nil : e.liveIndex, playlistID: e.livePlaylistID, lookID: e.lookID, savedAt: Date())
        var comparable = snap; comparable.savedAt = lastSession?.savedAt ?? snap.savedAt
        guard comparable != lastSession else { return }
        lastSession = snap
        snap.save(to: store.folder)
        // A marker file lets Scripts/update.sh (which runs outside the app) wait for a break in the service.
        let marker = store.folder.appendingPathComponent("live")
        if live != nil || e.mediaLayer != nil { try? Data().write(to: marker) } else { try? FileManager.default.removeItem(at: marker) }
    }

    func restoreSession() {
        guard let r = recovery else { return }
        recovery = nil
        if let look = r.lookID, store.look(look) != nil { engine.setLook(look) }
        if let id = r.presentationID, let i = r.index { engine.trigger(presentationID: id, index: i, playlistID: r.playlistID) }
    }

    func shutdown() {
        try? FileManager.default.removeItem(at: store.folder.appendingPathComponent("live"))
        SessionSnapshot(cleanExit: true, savedAt: Date()).save(to: store.folder)
        store.saveNow()
        outputs.renderers.values.forEach { $0.stop() }
        listening.stop()
    }

    @ObservationIgnored private var lastCC: [String: Int] = [:]

    private func handleMIDI(_ msg: MIDIMessage) {
        if msg.kind == .controlChange {
            // A fader or knob sends dozens of values; act once, when it crosses 64 going up.
            let key = "\(msg.channel)-\(msg.number)"
            let previous = lastCC[key] ?? 0
            lastCC[key] = msg.value
            guard msg.value >= 64, previous < 64 else { return }
        }
        for m in store.data.midiMappings where m.message.kind == msg.kind && m.message.channel == msg.channel
            && m.message.number == msg.number {
            engine.run(m.actions)
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
