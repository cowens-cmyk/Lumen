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

    // Motion background behind the live slide's words. Its own player, so a foreground video can play on top,
    // and AVPlayerLooper so the loop point is seamless.
    @ObservationIgnored private let bgPlayer = AVQueuePlayer()
    @ObservationIgnored private var bgLooper: AVPlayerLooper?
    @ObservationIgnored private var bgItemObservation: NSKeyValueObservation?
    @ObservationIgnored private var bgPump: DispatchSourceTimer?
    @ObservationIgnored private let bgOutput = OutputBox()
    /// File currently looping as the background (nil = none). Used to avoid restarting the same loop between slides.
    private(set) var backgroundLocation: String?
    /// Number of background frames delivered so far (for diagnostics and tests).
    var backgroundFrameCount: Int { bgOutput.frames }

    /// Thread-safe holder for the video output attached to the loop's current item.
    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _output: AVPlayerItemVideoOutput?
        private var _frames = 0
        var output: AVPlayerItemVideoOutput? {
            get { lock.lock(); defer { lock.unlock() }; return _output }
            set { lock.lock(); _output = newValue; lock.unlock() }
        }
        var frames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
        func bump() { lock.lock(); _frames += 1; lock.unlock() }
        func reset() { lock.lock(); _frames = 0; _output = nil; lock.unlock() }
    }

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

    /// Starts (or keeps) a muted, seamlessly looping video behind the live slide. Passing the file that's already
    /// looping does nothing, so the loop doesn't restart when the next slide of the same song goes live.
    func setBackground(_ ref: MediaRef?) {
        guard let ref, ref.kind == .video, let url = ref.url else { stopBackground(); return }
        if backgroundLocation == ref.location, bgLooper != nil { return }
        stopBackground()
        backgroundLocation = ref.location
        bgPlayer.isMuted = true
        bgLooper = AVPlayerLooper(player: bgPlayer, templateItem: AVPlayerItem(url: url))
        let box = bgOutput
        // The looper swaps in a fresh item each pass; give every one its own output.
        bgItemObservation = bgPlayer.observe(\.currentItem, options: [.initial, .new]) { player, _ in
            guard let item = player.currentItem else { return }
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            item.add(out)
            box.output = out
        }
        bgPlayer.play()
        let t = DispatchSource.makeTimerSource(queue: pumpQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        t.setEventHandler {
            guard let out = box.output else { return }
            let time = out.itemTime(forHostTime: CACurrentMediaTime())
            if out.hasNewPixelBuffer(forItemTime: time),
               let pb = out.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                LiveFrames.shared.set(LiveFrames.backgroundKey, CIImage(cvPixelBuffer: pb))
                box.bump()
            }
        }
        t.resume()
        bgPump = t
    }

    func stopBackground() {
        bgPump?.cancel()
        bgPump = nil
        bgItemObservation = nil
        bgLooper?.disableLooping()
        bgLooper = nil
        bgPlayer.pause()
        bgPlayer.removeAllItems()
        bgOutput.reset()
        LiveFrames.shared.set(LiveFrames.backgroundKey, nil)
        backgroundLocation = nil
    }

    func stopAudio() {
        audioPlayer.pause()
        audioPlayer.replaceCurrentItem(with: nil)
        audioTrack = nil
    }
}
