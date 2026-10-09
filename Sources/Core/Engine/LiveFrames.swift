import CoreImage
import QuartzCore
import Foundation

/// Thread-safe mailbox of the most recent frame from each live video source.
/// Sources (video player, capture devices, browser, NDI receivers) write; screen renderers read.
final class LiveFrames: @unchecked Sendable {
    static let shared = LiveFrames()

    static let videoKey = "video"
    /// Looping motion background behind the live slide (separate from the foreground video layer).
    static let backgroundKey = "bgvideo"
    static let webKey = "web"
    static func captureKey(_ id: String) -> String { "capture:\(id)" }
    static func ndiKey(_ name: String) -> String { "ndi:\(name)" }

    private let lock = NSLock()
    private var frames: [String: CIImage] = [:]
    private var arrived: [String: CFTimeInterval] = [:]

    func set(_ key: String, _ image: CIImage?) {
        lock.lock()
        frames[key] = image
        arrived[key] = image == nil ? nil : CACurrentMediaTime()
        lock.unlock()
    }

    /// Live devices (capture cards, NDI) send continuously, so a feed that has gone quiet means the source died.
    /// A frozen last frame on the projector is worse than falling back to what's behind it, so those read as nil
    /// after `staleAfter`. Video players and web pages legitimately hold still and are never considered stale.
    nonisolated(unsafe) static var staleAfter: CFTimeInterval = 3

    func get(_ key: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let f = frames[key] else { return nil }
        if key.hasPrefix("capture:") || key.hasPrefix("ndi:"), let t = arrived[key], CACurrentMediaTime() - t > Self.staleAfter { return nil }
        return f
    }
}
