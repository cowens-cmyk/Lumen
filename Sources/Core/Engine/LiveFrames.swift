import CoreImage
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

    func set(_ key: String, _ image: CIImage?) {
        lock.lock(); frames[key] = image; lock.unlock()
    }

    func get(_ key: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return frames[key]
    }
}
