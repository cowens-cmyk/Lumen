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
    private(set) var lastError: String?

    static func devices() -> [CaptureDeviceInfo] {
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
                                                 mediaType: .video, position: .unspecified)
        return d.devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(deviceID: String) {
        guard sessions[deviceID] == nil else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                lastError = "Camera access is off. Enable it in System Settings → Privacy & Security → Camera."
                return
            }
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
