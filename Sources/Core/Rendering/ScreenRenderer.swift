import AppKit
import CoreImage
import CoreVideo
import Metal

enum SceneBackground {
    case none
    case color(RGBA)
    case image(CIImage, ScaleMode)
    /// A live source in `LiveFrames` (video, capture, web, NDI).
    case live(String, ScaleMode)
}

/// Everything a screen needs to draw a frame. Built on the main actor, read by the render queue.
struct ScreenScene {
    var themeBackground: SceneBackground = .none
    var media: SceneBackground = .none
    var slide: CIImage?
    var slideKey: String = ""
    var overlay: CIImage?
    var transition: Double = 0.3
    /// Opaque outputs get a black base; keyed outputs keep alpha.
    var opaque = true
}

protocol FrameSink: AnyObject {
    func send(_ buffer: CVPixelBuffer)
    func stop()
}

/// Composites one screen's layers at its frame rate and fans frames out to its sinks.
final class ScreenRenderer: @unchecked Sendable {
    let screenID: UUID
    let size: CGSize
    let fps: Double

    private let ciContext: CIContext
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()

    private var scene = ScreenScene()
    private var previousSlide: CIImage?
    private var transitionStart: CFTimeInterval = 0
    private var transitionDuration: Double = 0

    private var sinks: [FrameSink] = []
    private var poolAuxAttributes: CFDictionary?
    private var previewPending = false
    private let previews = NSHashTable<FrameDisplayView>.weakObjects()

    static let sharedContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         .cacheIntermediates: false])
        }
        return CIContext()
    }()

    init(screenID: UUID, size: CGSize, fps: Double) {
        self.screenID = screenID
        self.size = size
        self.fps = max(1, fps)
        self.ciContext = ScreenRenderer.sharedContext
        self.queue = DispatchQueue(label: "lumen.render.\(screenID.uuidString.prefix(6))", qos: .userInteractive)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                attrs as CFDictionary, &pool)
        poolAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
    }

    deinit { stop() }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.renderFrame() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock(); let s = sinks; sinks = []; lock.unlock()
        s.forEach { $0.stop() }
    }

    func addSink(_ sink: FrameSink) {
        lock.lock(); sinks.append(sink); lock.unlock()
    }

    func addPreview(_ view: FrameDisplayView) {
        lock.lock(); previews.add(view); lock.unlock()
    }

    func update(_ new: ScreenScene) {
        lock.lock()
        if new.slideKey != scene.slideKey {
            previousSlide = scene.slide
            transitionStart = CACurrentMediaTime()
            transitionDuration = new.transition
        }
        scene = new
        lock.unlock()
    }

    // MARK: - Compositing

    private var rect: CGRect { CGRect(origin: .zero, size: size) }

    private func place(_ image: CIImage, _ mode: ScaleMode) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return image }
        let sx = size.width / e.width, sy = size.height / e.height
        var t: CGAffineTransform
        switch mode {
        case .stretch:
            t = CGAffineTransform(scaleX: sx, y: sy)
        case .fill, .fit:
            let s = mode == .fill ? max(sx, sy) : min(sx, sy)
            t = CGAffineTransform(scaleX: s, y: s)
            let w = e.width * s, h = e.height * s
            t = t.concatenating(CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
        }
        let moved = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(t))
        return moved.cropped(to: rect)
    }

    private func image(for bg: SceneBackground) -> CIImage? {
        switch bg {
        case .none: return nil
        case .color(let c): return CIImage(color: CIColor(cgColor: c.cgColor)).cropped(to: rect)
        case .image(let img, let mode): return place(img, mode)
        case .live(let key, let mode): return LiveFrames.shared.get(key).map { place($0, mode) }
        }
    }

    /// Slide images are rendered at the screen size already; just normalise their origin.
    private func fit(_ img: CIImage) -> CIImage {
        img.extent.size == size ? img : place(img, .stretch)
    }

    private func renderFrame() {
        lock.lock()
        let s = scene
        let prev = previousSlide
        let tStart = transitionStart
        let tDur = transitionDuration
        let currentSinks = sinks
        let views = previews.allObjects
        lock.unlock()

        var out = s.opaque ? CIImage(color: .black).cropped(to: rect) : CIImage(color: .clear).cropped(to: rect)
        if let bg = image(for: s.themeBackground) { out = bg.composited(over: out) }
        if let m = image(for: s.media) { out = m.composited(over: out) }

        let progress = tDur > 0 ? min(1, (CACurrentMediaTime() - tStart) / tDur) : 1
        let cur = s.slide.map(fit)
        if progress < 1 {
            let from = prev.map(fit) ?? CIImage(color: .clear).cropped(to: rect)
            let to = cur ?? CIImage(color: .clear).cropped(to: rect)
            let f = CIFilter(name: "CIDissolveTransition", parameters: [
                kCIInputImageKey: from, kCIInputTargetImageKey: to, kCIInputTimeKey: progress,
            ])
            if let mixed = f?.outputImage?.cropped(to: rect) { out = mixed.composited(over: out) }
        } else if let cur {
            out = cur.composited(over: out)
        }
        if let o = s.overlay { out = fit(o).composited(over: out) }

        guard let pool else { return }
        var pb: CVPixelBuffer?
        // The threshold makes the pool refuse (drop a frame) instead of growing without bound if a consumer stalls.
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, poolAuxAttributes, &pb)
        guard let buffer = pb else { return }
        ciContext.render(out, to: buffer, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        for sink in currentSinks { sink.send(buffer) }
        if !views.isEmpty {
            lock.lock()
            let skip = previewPending
            previewPending = true
            lock.unlock()
            if !skip {
                DispatchQueue.main.async { [weak self] in
                    views.forEach { $0.show(buffer) }
                    self?.lock.lock(); self?.previewPending = false; self?.lock.unlock()
                }
            }
        }
    }
}

/// Displays pixel buffers with zero copies by handing their IOSurface to the layer.
final class FrameDisplayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Clear so keyed (transparent) outputs show what's behind them: checkerboard in previews, black in windows.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ buffer: CVPixelBuffer) {
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = surface
            CATransaction.commit()
        }
    }
}
