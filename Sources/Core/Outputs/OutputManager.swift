import AppKit
import CoreImage
import Observation
import SwiftUI

/// Turns live state into per-screen scenes and owns the renderers and their output sinks.
@MainActor
@Observable
final class OutputManager {
    let store: LibraryStore
    let engine: LiveEngine

    private(set) var renderers: [UUID: ScreenRenderer] = [:]
    private(set) var statusByScreen: [UUID: [String]] = [:]
    var outputsEnabled = true {
        didSet { rebuild() }
    }

    @ObservationIgnored private var slideCache: [UUID: (key: String, image: CIImage?)] = [:]
    @ObservationIgnored private var overlayCache: [UUID: (key: String, image: CIImage?)] = [:]
    @ObservationIgnored private var imageCache: [String: CIImage] = [:]
    @ObservationIgnored private var windows: [OutputWindow] = []
    /// Display outputs by "screenID#destinationIndex", so a display change can redo just those.
    @ObservationIgnored private var displayWindows: [String: OutputWindow] = [:]
    @ObservationIgnored private var destinationStatus: [UUID: [Int: String]] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var configSignature = ""

    init(store: LibraryStore, engine: LiveEngine) {
        self.store = store
        self.engine = engine
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDisplayRefresh() }
        }
        // If the control window is dragged onto a display that has an output, move that output away from it.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, w.identifier?.rawValue == OutputManager.mainWindowID else { return }
                self?.scheduleDisplayRefresh()
            }
        }
    }

    static let mainWindowID = "lumen.main"

    /// The display Lumen's control window is on. Outputs aren't put there (they'd cover the operator's controls).
    static var operatorScreen: NSScreen? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == mainWindowID }?.screen ?? NSScreen.screens.first
    }

    static var allowOutputOnOperatorDisplay: Bool { UserDefaults.standard.bool(forKey: "allowOutputOnOperatorDisplay") }

    /// Re-creates renderers and sinks if the screen configuration changed.
    func rebuildIfNeeded() {
        let sig = (try? JSONEncoder().encode(store.data.screens)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if sig != configSignature { rebuild() }
    }

    func rebuild() {
        configSignature = (try? JSONEncoder().encode(store.data.screens)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        renderers.values.forEach { $0.stop() }
        windows.forEach { $0.close() }
        windows = []
        displayWindows = [:]
        destinationStatus = [:]
        renderers = [:]
        slideCache = [:]
        overlayCache = [:]
        statusByScreen = [:]

        for screen in store.data.screens where screen.enabled {
            var size = screen.size
            var fps = screen.role == .stage ? min(screen.fps, 15) : screen.fps
            // A DeckLink output must receive frames in its exact video mode.
            for d in screen.destinations {
                if case .decklink(_, let mode, _) = d { size = mode.size; fps = mode.fps; break }
            }
            let r = ScreenRenderer(screenID: screen.id, size: size, fps: fps)
            var status: [String] = []
            destinationStatus[screen.id] = [:]
            if outputsEnabled {
                var claimed = Set<UInt32>()
                for (i, d) in screen.destinations.enumerated() {
                    switch d {
                    case .none: break
                    case .display(let id, let name):
                        attachDisplay(screen: screen, renderer: r, index: i, id: id, name: name, claimed: &claimed)
                    case .window:
                        let w = OutputWindow(floatingTitle: "\(screen.name) Output", size: size)
                        windows.append(w); r.addSink(w)
                        destinationStatus[screen.id]?[i] = "Window: live"
                    case .decklink(let device, let mode, let keyer):
                        let sink = DeckLinkSink(device: device, mode: mode, keyer: keyer)
                        destinationStatus[screen.id]?[i] = "DeckLink \(device): \(sink.status)"
                        if sink.isRunning { r.addSink(sink) }
                    case .ndi(let name):
                        let sink = NDISink(name: name, size: size, fps: fps)
                        destinationStatus[screen.id]?[i] = "NDI \(name): \(sink.status)"
                        if sink.isRunning { r.addSink(sink) }
                    }
                }
                status = screen.destinations.indices.compactMap { destinationStatus[screen.id]?[$0] }
            } else {
                status.append("Outputs disabled")
            }
            statusByScreen[screen.id] = status
            renderers[screen.id] = r
            r.start()
        }
        update()
    }

    // MARK: - Display outputs

    /// Puts an output window on a Mac display, safely: never on the operator's own screen, never two outputs on one
    /// display, and never guessing between identically named displays.
    private func attachDisplay(screen: Screen, renderer r: ScreenRenderer, index i: Int, id: UInt32, name: String, claimed: inout Set<UInt32>) {
        func note(_ s: String) { destinationStatus[screen.id]?[i] = s }
        var match = NSScreen.screens.first { $0.displayID == id }
        if match == nil {
            let sameName = NSScreen.screens.filter { $0.localizedName == name }
            if sameName.count == 1 { match = sameName[0] }
            else if sameName.count > 1 { note("Display \(name): can't tell which of \(sameName.count) identical displays this was. Pick it again in Setup → Screens"); return }
        }
        guard let ns = match else { note("Display \(name): not connected"); return }
        if ns == Self.operatorScreen, !Self.allowOutputOnOperatorDisplay {
            note("Skipped — Lumen's control window is on \(ns.localizedName); an output there would cover your controls"); return
        }
        guard claimed.insert(ns.displayID).inserted else { note("Skipped — another output already uses \(ns.localizedName)"); return }
        let w = OutputWindow(fullscreenOn: ns, title: screen.name)
        windows.append(w)
        displayWindows["\(screen.id)#\(i)"] = w
        r.addSink(w)
        note("Display \(ns.localizedName): live")
    }

    /// Displays came or went (a projector re-handshaking, a cable pulled): redo only the display windows. DeckLink, NDI
    /// and floating outputs keep running untouched, so the stream feed doesn't blip because a lobby TV woke up.
    func scheduleDisplayRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))   // these notifications arrive in bursts
            guard !Task.isCancelled else { return }
            self?.refreshDisplays()
        }
    }

    func refreshDisplays() {
        guard outputsEnabled else { return }
        var claimed = Set<UInt32>()
        for screen in store.data.screens where screen.enabled {
            guard let r = renderers[screen.id] else { continue }
            for (i, d) in screen.destinations.enumerated() {
                guard case .display(let id, let name) = d else { continue }
                if let old = displayWindows["\(screen.id)#\(i)"] {
                    r.removeSink(old); old.close()
                    windows.removeAll { $0 === old }
                    displayWindows["\(screen.id)#\(i)"] = nil
                }
                attachDisplay(screen: screen, renderer: r, index: i, id: id, name: name, claimed: &claimed)
            }
            statusByScreen[screen.id] = screen.destinations.indices.compactMap { destinationStatus[screen.id]?[$0] }
        }
    }

    // MARK: - Scene building

    func update() {
        for screen in store.data.screens where screen.enabled {
            guard let r = renderers[screen.id] else { continue }
            r.update(scene(for: screen, size: r.size))
        }
    }

    private func cachedImage(_ path: String) -> CIImage? {
        if let c = imageCache[path] { return c }
        guard let img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        if imageCache.count > 40 { imageCache.removeAll() }
        imageCache[path] = img
        return img
    }

    private func background(for m: MediaRef) -> SceneBackground {
        switch m.kind {
        case .video: .live(LiveFrames.videoKey, m.scale)
        case .image: cachedImage(m.location).map { .image($0, m.scale) } ?? .none
        case .capture: .live(LiveFrames.captureKey(m.location), m.scale)
        case .web: .live(LiveFrames.webKey, m.scale)
        case .ndi: .live(LiveFrames.ndiKey(m.location), m.scale)
        case .color: m.color.map { .color($0) } ?? .none
        case .audio: .none
        }
    }

    /// A slide/theme background. Videos come from the dedicated loop player; until its first frame arrives
    /// (or if it isn't the active loop) the theme color shows instead of a hole.
    private func themeBackground(for m: MediaRef, fallback: RGBA) -> SceneBackground {
        guard m.kind == .video else { return background(for: m) }
        return engine.media.backgroundLocation == m.location ? .liveOr(LiveFrames.backgroundKey, m.scale, fallback) : .color(fallback)
    }

    func scene(for screen: Screen, size: CGSize) -> ScreenScene {
        var scene = ScreenScene()
        scene.transition = store.data.settings.transitionSeconds

        if screen.role == .stage {
            let snap = stageSnapshot(for: screen)
            let key = "\(snap.current)|\(snap.currentChords.hashValue)|\(snap.nextChords.hashValue)|\(snap.key ?? "")|\(snap.next)|\(snap.clock)|\(snap.timers.map(\.1))|\(snap.message ?? "")|\(snap.notes)|\(snap.layout.hashValue)"
            scene.slide = cached(&slideCache, screen.id, key, size: size, opaque: true) { StageCanvas(s: snap) }
            scene.slideKey = key
            scene.transition = 0
            return scene
        }

        let cfg = engine.look?.config(for: screen.id) ?? ScreenLookConfig()
        let presentation = engine.livePresentation
        let mode = cfg.mode(for: presentation?.kind)
        let theme = engine.theme(for: screen)
        let current = engine.currentSlide

        scene.opaque = screen.role == .audience || mode == .fullSlide

        if cfg.layers.slide, mode == .fullSlide, current != nil {
            if let bm = engine.backgroundRef(for: presentation, theme: theme) { scene.themeBackground = themeBackground(for: bm, fallback: theme.background) }
            else { scene.themeBackground = .color(theme.background) }
        }

        if let m = engine.mediaLayer {
            let isLive = m.kind == .capture || m.kind == .ndi
            if (isLive && cfg.layers.liveVideo) || (!isLive && cfg.layers.background) {
                scene.media = background(for: m)
            }
        }

        if cfg.layers.slide, mode != .hidden, let cur = current {
            let text = engine.resolveTokens(cur.slide.text)
            let label = cur.slide.label
            let key = "\(cur.slide.id)|\(text)|\(label)|\(theme.hashValue)|\(mode.rawValue)"
            scene.slide = cached(&slideCache, screen.id, key, size: size, opaque: false) {
                SlideCanvas(text: text, label: label, theme: theme, mode: mode)
            }
            scene.slideKey = key
        } else {
            scene.slide = nil
            scene.slideKey = "empty"
        }

        let props = engine.activeProps.keys.compactMap { store.prop($0) }.sorted { $0.name < $1.name }
        let msg = engine.message
        if (cfg.layers.props && !props.isEmpty) || (cfg.layers.messages && msg != nil) {
            let key = "\(props.map(\.hashValue))|\(msg ?? "")|\(cfg.layers.props)|\(cfg.layers.messages)"
            scene.overlay = cached(&overlayCache, screen.id, key, size: size, opaque: false) {
                OverlayCanvas(props: props, message: msg, showProps: cfg.layers.props, showMessage: cfg.layers.messages)
            }
        }
        return scene
    }

    private func cached<V: View>(_ cache: inout [UUID: (key: String, image: CIImage?)], _ id: UUID, _ key: String,
                                 size: CGSize, opaque: Bool, _ make: () -> V) -> CIImage? {
        if let c = cache[id], c.key == key { return c.image }
        guard let img = Snapshot.render(make(), size: size, opaque: opaque) else {
            // A failed render must never blank the screen: keep what's showing and try again on the next change.
            return cache[id]?.image
        }
        cache[id] = (key, img)
        return img
    }

    func stageSnapshot(for screen: Screen) -> StageSnapshot {
        let layout = store.data.stageLayouts.first { $0.id == screen.stageLayoutID } ?? store.data.stageLayouts.first
            ?? StageLayout(name: "Default")
        let tf = DateFormatter(); tf.dateFormat = "h:mm:ss"
        let next = engine.nextSlide
        return StageSnapshot(
            layout: layout,
            current: engine.currentSlide.map { engine.resolveTokens($0.slide.text) } ?? "",
            currentChords: engine.currentSlide?.slide.chords ?? [],
            next: next?.slide.text ?? "",
            nextChords: next?.slide.chords ?? [],
            key: engine.livePresentation?.key,
            nextGroup: next?.groupName ?? "",
            notes: engine.currentSlide?.slide.notes ?? "",
            clock: tf.string(from: engine.now),
            timers: layout.timerIDs.compactMap { id in store.timer(id).map { ($0.name, engine.timerValue(id)) } },
            message: engine.stageMessage)
    }
}

enum Snapshot {
    @MainActor
    static func render<V: View>(_ view: V, size: CGSize, opaque: Bool) -> CIImage? {
        let r = ImageRenderer(content: view.frame(width: designSize.width, height: designSize.height)
            .environment(\.colorScheme, .dark))
        r.scale = size.width / designSize.width
        r.isOpaque = opaque
        guard let cg = r.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// A Mac display output (borderless, covers the display) or a floating preview window.
final class OutputWindow: NSObject, FrameSink, NSWindowDelegate {
    private let window: NSWindow
    private let view: FrameDisplayView
    private let pendingLock = NSLock()
    private var pending = false

    init(fullscreenOn screen: NSScreen, title: String) {
        view = FrameDisplayView(frame: screen.frame)
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        super.init()
        window.title = title
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    init(floatingTitle: String, size: CGSize) {
        let rect = NSRect(x: 200, y: 200, width: 960, height: 960 * size.height / size.width)
        view = FrameDisplayView(frame: rect)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = floatingTitle
        window.contentAspectRatio = size
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameAutosaveName("LumenOutput-\(floatingTitle)")
        window.orderFront(nil)
    }

    func send(_ buffer: CVPixelBuffer) {
        // Never queue more than one frame for the main thread; drop if it's busy.
        pendingLock.lock()
        if pending { pendingLock.unlock(); return }
        pending = true
        pendingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.show(buffer)
            self.pendingLock.lock(); self.pending = false; self.pendingLock.unlock()
        }
    }

    func stop() {
        DispatchQueue.main.async { [window] in window.orderOut(nil) }
    }

    func close() { window.orderOut(nil) }
}
