import CoreImage
import CoreVideo
import Foundation

/// Sends a screen to a Blackmagic DeckLink output (e.g. one connector of a DeckLink 8K Pro).
final class DeckLinkSink: FrameSink {
    private let output: LMDeckLinkOutput?
    private(set) var isRunning = false
    private(set) var status: String
    private let queue = DispatchQueue(label: "lumen.decklink", qos: .userInteractive)
    private var busy = false
    private let lock = NSLock()

    init(device: String, mode: VideoMode, keyer: Bool) {
        guard LMDeckLinkOutput.sdkCompiledIn() else {
            output = nil
            status = "built without DeckLink SDK"
            return
        }
        guard LMDeckLinkOutput.driverAvailable() else {
            output = nil
            status = "Desktop Video driver not installed"
            return
        }
        guard let o = LMDeckLinkOutput(deviceName: device) else {
            output = nil
            status = "device not found"
            return
        }
        output = o
        do {
            try o.start(withMode: mode.rawValue, keying: keyer)
            isRunning = true
            status = "live \(mode.title)\(keyer ? " fill+key" : "")"
        } catch {
            status = error.localizedDescription
        }
    }

    static var deviceNames: [String] {
        LMDeckLinkOutput.devices().filter(\.supportsOutput).map(\.name)
    }

    func send(_ buffer: CVPixelBuffer) {
        guard isRunning, let output else { return }
        // Drop frames rather than queueing if the card is behind; never block the compositor.
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            output.displayPixelBuffer(buffer)
            self?.lock.lock(); self?.busy = false; self?.lock.unlock()
        }
    }

    func stop() {
        isRunning = false
        queue.sync { output?.stop() }
    }
}

/// Publishes a screen as an NDI source (with alpha) for vMix, OBS, TriCaster, etc.
final class NDISink: FrameSink {
    private let sender: LMNDISender?
    private let fps: Double
    private(set) var isRunning = false
    private(set) var status: String
    private let queue = DispatchQueue(label: "lumen.ndi.send", qos: .userInteractive)

    init(name: String, size: CGSize, fps: Double) {
        self.fps = fps
        guard LMNDI.sdkCompiledIn() else {
            sender = nil; status = "built without NDI SDK"; return
        }
        guard LMNDI.runtimeAvailable() else {
            sender = nil; status = "NDI runtime not installed (install NDI Tools)"; return
        }
        sender = LMNDISender(name: name)
        isRunning = sender != nil
        status = isRunning ? "live" : "couldn't create sender"
    }

    func send(_ buffer: CVPixelBuffer) {
        guard let sender else { return }
        let fps = fps
        queue.async { sender.send(buffer, frameRate: fps) }
    }

    func stop() {
        isRunning = false
        queue.sync { sender?.stop() }
    }
}

/// NDI inputs used as live video layers.
@MainActor
final class NDIReceiveManager {
    private var receivers: [String: LMNDIReceiver] = [:]
    private(set) var lastError: String?

    var available: Bool { LMNDI.sdkCompiledIn() && LMNDI.runtimeAvailable() }

    func sources() async -> [String] {
        guard available else { return [] }
        return await Task.detached { LMNDI.findSources(waiting: 1500) }.value
    }

    func start(source: String) {
        guard receivers[source] == nil else { return }
        guard available else {
            lastError = LMNDI.sdkCompiledIn() ? "Install NDI Tools to receive NDI." : "Lumen was built without the NDI SDK."
            return
        }
        let key = LiveFrames.ndiKey(source)
        receivers[source] = LMNDIReceiver(source: source) { pb in
            LiveFrames.shared.set(key, CIImage(cvPixelBuffer: pb))
        }
    }

    func stop(source: String) {
        receivers[source]?.stop()
        receivers[source] = nil
        LiveFrames.shared.set(LiveFrames.ndiKey(source), nil)
    }
}
