import Foundation
import Observation

/// What is on screen right now, and every action that changes it.
@MainActor
@Observable
final class LiveEngine {
    let store: LibraryStore

    // Live slide
    private(set) var livePresentationID: UUID?
    private(set) var liveIndex: Int?
    /// Which slide (by id) is live, and a copy of what the room is seeing. If the live song is edited or deleted
    /// underneath, the outputs keep showing this until the operator picks something else; they never go blank.
    private(set) var liveSlideID: UUID?
    private(set) var lastShown: SlideRef?
    private(set) var livePlaylistID: UUID?
    private(set) var slideCleared = true

    // Layers
    private(set) var lookID: UUID?
    private(set) var mediaLayer: MediaRef?
    /// The slide whose own video is on the media layer. That video belongs to the slide: it's cleared when a different
    /// slide goes live, and its end-of-video actions only run while that slide is still the live one.
    private(set) var mediaOwnerSlideID: UUID?
    private(set) var activeProps: [UUID: Date] = [:]
    private(set) var message: String?
    private(set) var stageMessage: String?
    /// A stage template put up by an action or a presentation-type default; nil = each stage screen's own layout.
    private(set) var stageLayoutOverride: UUID?

    // Timers & slideshow
    private(set) var timers: [UUID: TimerRuntime] = [:]
    private(set) var slideshowInterval: Double?
    var now = Date()

    /// Ephemeral presentations (e.g. a scripture passage built on the fly) that aren't saved to the library.
    private(set) var transient: [UUID: Presentation] = [:]

    /// Bumped on any change the renderers care about.
    private(set) var revision = 0

    @ObservationIgnored var media: MediaEngine! {
        didSet { media.onFinished = { [weak self] ref in self?.mediaFinished(ref) } }
    }
    @ObservationIgnored var capture: CaptureManager!
    @ObservationIgnored var browser: BrowserController!
    @ObservationIgnored var ndiIn: NDIReceiveManager!
    @ObservationIgnored var midi: MIDIManager!
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onSlideTriggered: ((Presentation, Int) -> Void)?
    @ObservationIgnored private var slideshowTask: Task<Void, Never>?
    /// The presentation the running slideshow belongs to; it stops if anything else goes live or the slide is cleared.
    @ObservationIgnored private var slideshowOwner: UUID?
    @ObservationIgnored private var actionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var actionNavigations: [Date] = []
    /// Called with a human-readable problem (missing media file, runaway actions) so the app can tell the operator.
    @ObservationIgnored var onProblem: ((String) -> Void)?
    @ObservationIgnored private var propHideTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var clock: Timer?

    init(store: LibraryStore) {
        self.store = store
        lookID = store.data.settings.defaultLookID ?? store.data.looks.first?.id
        for t in store.data.timers { timers[t.id] = TimerRuntime() }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // countdowns and the stage clock must not stall while a menu is open
        clock = t
    }

    private func tick() {
        let previous = Int(now.timeIntervalSince1970)
        now = Date()
        // Timer and clock tokens change once a second.
        if Int(now.timeIntervalSince1970) != previous { changed(redrawOnly: true) }
    }

    private func changed(redrawOnly: Bool = false) {
        revision &+= 1
        onChange?()
    }

    // MARK: - Derived state

    func presentation(_ id: UUID?) -> Presentation? {
        guard let id else { return nil }
        return transient[id] ?? store.presentation(id)
    }

    var livePresentation: Presentation? { presentation(livePresentationID) }

    var liveSlides: [SlideRef] { livePresentation?.orderedSlides ?? [] }

    /// Where the live slide is now: its remembered position if that still holds the same slide, else wherever that
    /// slide moved to after an edit or reorder.
    var resolvedIndex: Int? {
        let slides = liveSlides
        if let i = liveIndex, slides.indices.contains(i), liveSlideID == nil || slides[i].slide.id == liveSlideID { return i }
        if let id = liveSlideID, let j = slides.firstIndex(where: { $0.slide.id == id }) { return j }
        return nil
    }

    var currentSlide: SlideRef? {
        guard !slideCleared, liveIndex != nil else { return nil }
        if let i = resolvedIndex { return liveSlides[i] }
        return lastShown   // the slide vanished (song edited/deleted): keep what the room is seeing
    }

    /// The upcoming slide, crossing into the next playlist item if needed.
    var nextSlide: SlideRef? {
        guard let i = resolvedIndex ?? liveIndex else { return nil }
        if let s = liveSlides[safe: i + 1] { return s }
        if let next = nextPlaylistPresentation() { return next.orderedSlides.first }
        return nil
    }

    var look: Look? { store.look(lookID) ?? store.data.looks.first }

    func theme(for screen: Screen) -> Theme {
        let p = livePresentation
        if let kind = p?.kind, let tid = look?.config(for: screen.id).themeByKind[kind], let t = store.theme(tid) {
            return t
        }
        return store.resolvedTheme(for: p, slide: currentSlide?.slide)
    }

    func timerValue(_ id: UUID) -> String {
        guard let t = store.timer(id) else { return "--:--" }
        return TimerRuntime.format((timers[id] ?? TimerRuntime()).value(for: t, at: now))
    }

    /// Replaces {clock}, {time}, {date} and {timer:Name} tokens.
    func resolveTokens(_ text: String) -> String {
        guard text.contains("{") else { return text }
        var s = text
        let tf = DateFormatter(); tf.dateFormat = "h:mm"
        let df = DateFormatter(); df.dateStyle = .long
        s = s.replacingOccurrences(of: "{clock}", with: tf.string(from: now))
        s = s.replacingOccurrences(of: "{time}", with: tf.string(from: now))
        s = s.replacingOccurrences(of: "{date}", with: df.string(from: now))
        for t in store.data.timers {
            s = s.replacingOccurrences(of: "{timer:\(t.name)}", with: timerValue(t.id))
        }
        return s
    }

    // MARK: - Triggering slides

    func trigger(_ presentation: Presentation, index: Int, playlistID: UUID? = nil) {
        if store.presentation(presentation.id) == nil { transient[presentation.id] = presentation }
        let slides = presentation.orderedSlides
        let sameSlide = livePresentationID == presentation.id && liveIndex == index && !slideCleared
        guard slides.indices.contains(index) else {
            // Media-only presentations without slides still play their media.
            if slides.isEmpty, let m = presentation.groups.first?.slides.first?.media { playMedia(m) }
            return
        }
        let entering = livePresentationID != presentation.id || slideCleared
        if let owner = slideshowOwner, owner != presentation.id { stopSlideshow() }   // a slideshow never outlives its presentation
        livePresentationID = presentation.id
        liveIndex = index
        liveSlideID = slides[index].slide.id
        lastShown = slides[index]
        if let playlistID { livePlaylistID = playlistID }
        slideCleared = false
        let slide = slides[index].slide
        if let m = slide.media {
            // Media that's already up isn't restarted when the next slide shares it (looping backgrounds keep going),
            // but clicking the same slide again, or a video that has already finished, plays it again.
            let finished = m.kind == .video && !m.loop && !media.isPlaying
            if sameSlide || finished || mediaLayer?.location != m.location { playMedia(m, owner: slide.id) }
            else { mediaOwnerSlideID = slide.id }
        } else if mediaOwnerSlideID != nil, mediaOwnerSlideID != slide.id, mediaLayer?.kind == .video, mediaLayer?.loop == false {
            clear(.media)   // the clip belonged to the slide we just left
        }
        syncBackground()
        if entering { applyKindDefaults(for: presentation.kind) }
        changed()
        if !slide.actions.isEmpty { run(slide.actions) }
        if presentation.slideshow.enabled, slideshowInterval == nil { startSlideshow(interval: presentation.slideshow.interval) }
        onSlideTriggered?(presentation, index)
    }

    func trigger(presentationID: UUID, index: Int, playlistID: UUID? = nil) {
        guard let p = presentation(presentationID) else { return }
        trigger(p, index: index, playlistID: playlistID)
    }

    func next() {
        guard let p = livePresentation else { return }
        let i = (slideCleared ? -1 : (resolvedIndex ?? liveIndex ?? -1)) + 1
        if i < p.orderedSlides.count {
            trigger(p, index: i)
        } else if let n = nextPlaylistPresentation() {
            trigger(n, index: 0)
        } else if p.slideshow.loop, slideshowInterval != nil {
            trigger(p, index: 0)
        }
    }

    func previous() {
        guard let p = livePresentation, let i = resolvedIndex ?? liveIndex else { return }
        if i > 0 { trigger(p, index: min(i - 1, max(0, p.orderedSlides.count - 1))) }
        else if let prev = adjacentPlaylistPresentation(offset: -1) { trigger(prev, index: max(0, prev.orderedSlides.count - 1)) }
    }

    private func adjacentPlaylistPresentation(offset: Int) -> Presentation? {
        guard let plID = livePlaylistID, let pl = store.data.playlists.first(where: { $0.id == plID }),
              let current = livePresentationID else { return nil }
        let ids: [UUID] = pl.items.compactMap { if case .presentation(let id) = $0.kind { id } else { nil } }
        guard let idx = ids.firstIndex(of: current) else { return nil }
        var j = idx + offset
        while ids.indices.contains(j) {
            if let p = presentation(ids[j]), !p.orderedSlides.isEmpty { return p }
            j += offset
        }
        return nil
    }

    private func nextPlaylistPresentation() -> Presentation? { adjacentPlaylistPresentation(offset: 1) }

    // MARK: - Backgrounds

    /// What sits behind the live slide's words: the song's own background, else its theme's.
    func backgroundRef(for p: Presentation?, theme: Theme? = nil) -> MediaRef? {
        p?.background ?? (theme ?? store.resolvedTheme(for: p)).backgroundMedia
    }

    /// Keeps the looping background player in step with the live slide. A loop belongs to the slide that's showing:
    /// it stops when the slide is cleared, and keeps running (no restart) across slides that share it.
    private func syncBackground() {
        guard !slideCleared, let p = livePresentation else { media.setBackground(nil); return }
        media.setBackground(backgroundRef(for: p))
    }

    // MARK: - When a video ends

    /// A video finished playing on its own: run its end actions (e.g. go to the next slide after a countdown).
    private func mediaFinished(_ ref: MediaRef) {
        guard mediaLayer?.id == ref.id, let actions = ref.onEnd, !actions.isEmpty else { return }
        // If the operator already moved on from the slide that started this video, don't skip anything.
        if let owner = mediaOwnerSlideID, slideCleared || currentSlide?.slide.id != owner { return }
        run(actions)
    }

    // MARK: - Layers

    /// Stops whatever currently owns the media layer (its player, capture session, NDI receiver or web page) so
    /// nothing keeps running — or making sound — invisibly underneath the next thing.
    private func stopMediaLayer(replacingWith newKind: MediaKind? = nil) {
        guard let m = mediaLayer else { return }
        switch m.kind {
        case .video: media.stop()
        case .capture: capture.stop(deviceID: m.location)
        case .ndi: ndiIn.stop(source: m.location)
        case .web: if newKind != .web { browser.close() }
        case .image, .color, .audio: break
        }
    }

    func playMedia(_ m: MediaRef, owner: UUID? = nil) {
        // A missing file must not replace what's on screen with a stale frame: say so and leave things alone.
        if m.kind == .video || m.kind == .audio || m.kind == .image, let url = m.url, !FileManager.default.fileExists(atPath: url.path) {
            onProblem?("Can't find “\(m.displayName)”. The file was moved or deleted: \(url.path)")
            return
        }
        if m.kind != .audio { stopMediaLayer(replacingWith: m.kind) }
        mediaOwnerSlideID = owner
        switch m.kind {
        case .video, .audio: media.play(m)
        case .capture: capture.start(deviceID: m.location)
        case .web: browser.load(m.location)
        case .ndi: ndiIn.start(source: m.location)
        case .image, .color: break
        }
        if m.kind != .audio { mediaLayer = m }
        changed()
    }

    func clear(_ target: ClearTarget) {
        switch target {
        case .all:
            actionTasks.values.forEach { $0.cancel() }   // delayed actions from a macro must not fire after Clear All
            actionTasks = [:]
            clear(.slide); clear(.media); clear(.props); clear(.messages); clear(.audio)
            stageLayoutOverride = nil
            stopSlideshow()
        case .slide:
            slideCleared = true
            stopSlideshow()
            syncBackground()
        case .media:
            mediaOwnerSlideID = nil
            stopMediaLayer()
            mediaLayer = nil
        case .props:
            activeProps = [:]
            propHideTasks.values.forEach { $0.cancel() }
            propHideTasks = [:]
        case .messages:
            message = nil
        case .audio:
            media.stopAudio()
        }
        changed()
    }

    func setLook(_ id: UUID) {
        lookID = id
        changed()
    }

    func showProp(_ id: UUID) {
        activeProps[id] = Date()
        propHideTasks[id]?.cancel()
        if let p = store.prop(id), p.autoHideSeconds > 0 {
            propHideTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(p.autoHideSeconds))
                guard !Task.isCancelled else { return }
                self?.hideProp(id)
            }
        }
        changed()
    }

    func hideProp(_ id: UUID) {
        activeProps[id] = nil
        propHideTasks[id]?.cancel()
        propHideTasks[id] = nil
        changed()
    }

    func toggleProp(_ id: UUID) { activeProps[id] == nil ? showProp(id) : hideProp(id) }

    func showMessage(_ text: String?) {
        message = (text?.isEmpty ?? true) ? nil : text
        changed()
    }

    func setStageLayout(_ id: UUID?) {
        // An id for a deleted template must not blank the stage: fall back to the screen's own layout.
        stageLayoutOverride = id.flatMap { target in store.data.stageLayouts.contains { $0.id == target } ? target : nil }
        changed()
    }

    /// When a presentation of a type goes live: its stage template goes up (or the default returns), and its
    /// default actions run (start the sermon timer, set a look…), whichever way the operator got there.
    private func applyKindDefaults(for kind: PresentationKind) {
        let s = store.data.settings
        stageLayoutOverride = s.stageLayoutByKind[kind.rawValue].flatMap { id in
            store.data.stageLayouts.contains { $0.id == id } ? id : nil
        }
        if let actions = s.actionsByKind[kind.rawValue], !actions.isEmpty { run(actions) }
    }

    func setStageMessage(_ text: String?) {
        stageMessage = (text?.isEmpty ?? true) ? nil : text
        changed()
    }

    // MARK: - Timers

    func startTimer(_ id: UUID) {
        var r = timers[id] ?? TimerRuntime()
        guard !r.running else { return }
        r.running = true
        r.startedAt = Date()
        timers[id] = r
        changed()
    }

    func stopTimer(_ id: UUID) {
        guard var r = timers[id], r.running else { return }
        r.accumulated = r.elapsed(at: Date())
        r.running = false
        r.startedAt = nil
        timers[id] = r
        changed()
    }

    func resetTimer(_ id: UUID) {
        let wasRunning = timers[id]?.running ?? false
        timers[id] = TimerRuntime(running: wasRunning, startedAt: wasRunning ? Date() : nil)
        changed()
    }

    // MARK: - Slideshow

    func startSlideshow(interval: Double) {
        slideshowTask?.cancel()
        slideshowInterval = interval
        let owner = livePresentationID
        slideshowOwner = owner
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(0.5, interval)))
                guard !Task.isCancelled, let self else { return }
                // It only advances its own presentation, and only while that slide is still up.
                guard !self.slideCleared, self.livePresentationID == owner else { self.stopSlideshow(); return }
                self.next()
            }
        }
    }

    func stopSlideshow() {
        slideshowTask?.cancel()
        slideshowTask = nil
        slideshowInterval = nil
        slideshowOwner = nil
    }

    // MARK: - Actions & macros

    func runMacro(_ id: UUID) {
        guard let m = store.macro(id) else { return }
        run(m.actions)
    }

    /// Runs actions in the background, cancellably (Clear All cancels anything still waiting on a delay).
    func run(_ actions: [SlideAction]) {
        let id = UUID()
        actionTasks[id] = Task { [weak self] in
            await self?.perform(actions)
            self?.actionTasks[id] = nil
        }
    }

    /// Actions that move between slides can chain into themselves (a slide whose action re-triggers its own slide).
    /// Past a dozen navigations in two seconds, stop obeying them and tell the operator.
    private func navigationAllowed() -> Bool {
        let now = Date()
        actionNavigations.removeAll { now.timeIntervalSince($0) > 2 }
        guard actionNavigations.count < 12 else {
            if actionNavigations.count == 12 { onProblem?("A slide action keeps triggering slides in a loop, so it was stopped."); actionNavigations.append(now) }
            return false
        }
        actionNavigations.append(now)
        return true
    }

    func perform(_ actions: [SlideAction], depth: Int = 0) async {
        guard depth < 8 else { return } // guards against macros that call each other forever
        for a in actions {
            if Task.isCancelled { return }
            switch a {
            case .triggerMacro(let id):
                if let m = store.macro(id) { await perform(m.actions, depth: depth + 1) }
            case .setLook(let id): setLook(id)
            case .showProp(let id): showProp(id)
            case .hideProp(let id): hideProp(id)
            case .startTimer(let id): startTimer(id)
            case .stopTimer(let id): stopTimer(id)
            case .resetTimer(let id): resetTimer(id)
            case .sendMIDI(let msg): midi.send(msg)
            case .clear(let t): clear(t)
            case .playMedia(let m): playMedia(m)
            case .showMessage(let s): showMessage(s)
            case .stageMessage(let s): setStageMessage(s)
            case .setStageLayout(let id): setStageLayout(id)
            case .resetStageLayout: setStageLayout(nil)
            case .triggerPresentation(let id, let slide): if navigationAllowed() { trigger(presentationID: id, index: slide) }
            case .nextSlide: if navigationAllowed() { next() }
            case .previousSlide: if navigationAllowed() { previous() }
            case .startSlideshow(let i): startSlideshow(interval: i)
            case .stopSlideshow: stopSlideshow()
            case .openWeb(let url):
                playMedia(MediaRef(kind: .web, location: url))
            case .delay(let s):
                try? await Task.sleep(for: .seconds(s))
            }
        }
    }

    func syncTimersWithLibrary() {
        for t in store.data.timers where timers[t.id] == nil { timers[t.id] = TimerRuntime() }
    }
}
