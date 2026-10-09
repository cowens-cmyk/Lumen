import AVFoundation
import CoreImage
import Observation

/// Plays video/audio for the media layer and publishes frames to `LiveFrames`.
@MainActor
@Observable
final class MediaEngine {
    private(set) var current: MediaRef?
    private(set) var audioTrack: MediaRef?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let audioPlayer = AVPlayer()
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var pump: DispatchSourceTimer?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let pumpQueue = DispatchQueue(label: "lumen.media.pump", qos: .userInteractive)

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
    }

    func play(_ m: MediaRef) {
        guard let url = m.url else { return }
        if m.kind == .audio {
            audioTrack = m
            audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            audioPlayer.volume = Float(m.volume)
            audioPlayer.play()
            return
        }
        stopPump()
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        output = out
        player.replaceCurrentItem(with: item)
        player.isMuted = m.muted
        player.volume = Float(m.volume)
        current = m
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.current?.loop == true {
                    self.player.seek(to: .zero)
                    self.player.play()
                } else {
                    self.isPlaying = false
                }
            }
        }
        player.play()
        isPlaying = true
        startPump(out)
    }

    private func startPump(_ out: AVPlayerItemVideoOutput) {
        let t = DispatchSource.makeTimerSource(queue: pumpQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        t.setEventHandler {
            let time = out.itemTime(forHostTime: CACurrentMediaTime())
            if out.hasNewPixelBuffer(forItemTime: time),
               let pb = out.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                LiveFrames.shared.set(LiveFrames.videoKey, CIImage(cvPixelBuffer: pb))
            }
        }
        t.resume()
        pump = t
    }

    private func stopPump() {
        pump?.cancel()
        pump = nil
    }

    func togglePause() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        stopPump()
        LiveFrames.shared.set(LiveFrames.videoKey, nil)
        current = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    func stopAudio() {
        audioPlayer.pause()
        audioPlayer.replaceCurrentItem(with: nil)
        audioTrack = nil
    }
}
