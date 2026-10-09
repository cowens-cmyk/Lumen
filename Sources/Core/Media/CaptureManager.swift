import AVFoundation
import CoreImage

struct CaptureDeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
}

/// Live video inputs: Apple TV through a capture card, cameras, and DeckLink inputs
/// (Blackmagic Desktop Video exposes those to AVFoundation).
@MainActor
final class CaptureManager {
    private var sessions: [String: (AVCaptureSession, FrameReceiver)] = [:]
    /// Devices whose start is waiting on the camera-permission prompt; guards against two quick starts both opening it.
    private var starting: Set<String> = []
    private(set) var lastError: String?
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?

    init() {
        // An unplugged capture card or camera: stop the session. The frozen last frame is also treated as stale elsewhere.
        disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let id = (note.object as? AVCaptureDevice)?.uniqueID else { return }
                self?.stop(deviceID: id)
                self?.lastError = "A capture device was disconnected."
            }
        }
    }

    static func devices() -> [CaptureDeviceInfo] {
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
                                                 mediaType: .video, position: .unspecified)
        return d.devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(deviceID: String) {
        guard sessions[deviceID] == nil, !starting.contains(deviceID) else { return }
        starting.insert(deviceID)
        Task {
            defer { starting.remove(deviceID) }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                lastError = "Camera access is off. Enable it in System Settings → Privacy & Security → Camera."
                return
            }
            // stop() may have been called while the permission check was pending.
            guard starting.contains(deviceID) else { return }
            guard let device = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: device) else {
                lastError = "Capture device not found."
                return
            }
            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
            guard session.canAddInput(input) else { lastError = "Device busy."; return }
            session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            let receiver = FrameReceiver(key: LiveFrames.captureKey(deviceID))
            out.setSampleBufferDelegate(receiver, queue: receiver.queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            session.commitConfiguration()
            sessions[deviceID] = (session, receiver)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }
    }

    func stop(deviceID: String) {
        starting.remove(deviceID)
        guard let (session, _) = sessions.removeValue(forKey: deviceID) else { return }
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        LiveFrames.shared.set(LiveFrames.captureKey(deviceID), nil)
    }

    func stopAll() { sessions.keys.forEach { stop(deviceID: $0) } }
}

final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let key: String
    let queue = DispatchQueue(label: "lumen.capture", qos: .userInteractive)

    init(key: String) { self.key = key }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        LiveFrames.shared.set(key, CIImage(cvPixelBuffer: pb))
    }
}
