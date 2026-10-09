import AVFoundation
import CoreAudio
import Observation
import Speech

struct AudioInputDevice: Identifiable, Hashable {
    var id: String   // UID
    var name: String
    var deviceID: AudioDeviceID
}

/// On-device speech recognition from a chosen audio input (e.g. the worship leader's mic feed
/// from the sound board, or the pastor's lav). Drives lyric following and scripture detection.
@MainActor
@Observable
final class ListeningService {
    enum Mode: String { case off, lyrics, scripture, both }

    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var level: Float = 0
    private(set) var lastError: String?
    private(set) var confidence: Double = 0
    private(set) var status = "Off"
    private(set) var suggestedIndex: Int?
    private(set) var detections: [ScriptureDetection] = []

    var followLyrics = false {
        didSet { if !followLyrics { status = isListening ? "Listening" : "Off" } }
    }
    var detectScripture = true
    var autoAdvance = true

    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var restartTimer: Timer?
    @ObservationIgnored private var follower = LyricFollower()
    @ObservationIgnored private var detector = ScriptureDetector()
    @ObservationIgnored private var loadedPresentationID: UUID?
    @ObservationIgnored private var loadedRevision: Date?
    /// Words already "spent" on a previous slide in the current recognition task.
    @ObservationIgnored private var consumedWords = 0
    @ObservationIgnored weak var engine: LiveEngine?
    @ObservationIgnored var settings: (() -> AppSettings)?

    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &ssize)
            guard ssize > 0 else { return nil }
            func str(_ sel: AudioObjectPropertySelector) -> String {
                var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var cf: Unmanaged<CFString>?
                var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, let v = cf?.takeRetainedValue() else { return "" }
                return v as String
            }
            return AudioInputDevice(id: str(kAudioDevicePropertyDeviceUID), name: str(kAudioObjectPropertyName), deviceID: id)
        }
    }

    func start() async {
        guard !isListening else { return }
        let s = settings?() ?? AppSettings()
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else {
            lastError = "Allow Speech Recognition in System Settings → Privacy & Security."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            lastError = "Allow Microphone access in System Settings → Privacy & Security."
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: s.speechLocale))
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition isn't available for \(s.speechLocale)."
            return
        }

        // Route the chosen input device (e.g. a Dante/USB feed from the board) into the engine.
        if !s.listenInputDeviceUID.isEmpty,
           let dev = Self.inputDevices().first(where: { $0.id == s.listenInputDeviceUID }),
           let unit = audio.inputNode.audioUnit {
            var id = dev.deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        // With no input device (or a saved one that's gone) the format has no sample rate, and installing a tap on it
        // raises an exception that would take the whole app down. Check first.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "No audio input is available. Plug one in (or pick another in the list) and try again."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            // Runs on the audio thread: append to the current request and meter.
            self?.append(buffer)
        }
        do {
            audio.prepare()
            try audio.start()
        } catch {
            lastError = "Couldn't start audio input: \(error.localizedDescription)"
            return
        }
        isListening = true
        lastError = nil
        status = "Listening"
        beginTask()
        // Recognition tasks degrade after about a minute; roll them over.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginTask() }
        }
    }

    /// The request the audio thread feeds, swapped on the main thread every ~50 s: guarded by a lock.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func append(_ b: AVAudioPCMBuffer) { lock.lock(); request?.append(b); lock.unlock() }
    }
    @ObservationIgnored private let requestBox = RequestBox()
    @ObservationIgnored nonisolated(unsafe) private var meter: Float = 0
    @ObservationIgnored private var errorStreak = 0

    nonisolated private func append(_ buffer: AVAudioPCMBuffer) {
        requestBox.append(buffer)
        if let ch = buffer.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
            meter = sqrt(sum / Float(max(1, n / 4)))
        }
    }

    private func beginTask() {
        task?.finish()
        request?.endAudio()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = contextualStrings()
        request = req
        requestBox.set(req)
        consumedWords = 0
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            Task { @MainActor in
                guard let self else { return }
                if let text { self.errorStreak = 0; self.handle(text) }
                if error != nil, self.isListening, self.request === req {
                    // Silence or a hiccup ended the task: start a fresh one, backing off if it keeps failing
                    // (an unavailable recognizer must not become a tight loop on the main thread).
                    self.errorStreak += 1
                    let delay = min(8.0, 0.5 * pow(2.0, Double(self.errorStreak - 1)))
                    try? await Task.sleep(for: .seconds(delay))
                    if self.isListening, self.request === req { self.beginTask() }
                }
            }
        }
    }

    private func contextualStrings() -> [String] {
        var out = BibleBooks.all.map(\.name)
        if let p = engine?.livePresentation, p.kind == .song {
            // Help the recognizer with this song's distinctive lines.
            out += p.groups.flatMap(\.slides).flatMap { $0.text.components(separatedBy: "\n") }.prefix(60)
        }
        return Array(out.prefix(100))
    }

    func stop() {
        // Touching `audio.inputNode` binds to the input device (and can block), so only tear down what was started.
        guard isListening || task != nil else { return }
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        requestBox.set(nil)
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        isListening = false
        status = "Off"
        confidence = 0
        level = 0
    }

    func takeOver() {
        followLyrics = false
        status = "Operator in control"
        confidence = 0
    }

    func dismiss(_ d: ScriptureDetection) { detections.removeAll { $0.id == d.id } }

    private func handle(_ text: String) {
        transcript = String(text.suffix(400))
        level = meter

        if detectScripture {
            var det = detector
            let found = det.scan(text)
            detector = det
            if !found.isEmpty {
                detections.insert(contentsOf: found.reversed(), at: 0)
                if detections.count > 20 { detections.removeLast(detections.count - 20) }
            }
        }

        guard followLyrics, let engine, let p = engine.livePresentation else { return }
        if loadedPresentationID != p.id || loadedRevision != p.updatedAt {
            follower.load(p.orderedSlides.map(\.slide.text))
            loadedPresentationID = p.id
            loadedRevision = p.updatedAt
        }
        follower.threshold = settings?().lyricFollowThreshold ?? 0.62
        let current = engine.slideCleared ? nil : engine.liveIndex
        let words = text.split(separator: " ")
        if consumedWords > words.count { consumedWords = 0 }
        let tail = words[consumedWords...].suffix(14).joined(separator: " ")
        let d = follower.update(heardText: tail, current: current)
        confidence = d.confidence
        suggestedIndex = d.bestIndex
        switch d.kind {
        case .hold:
            status = d.confidence > 0.5 ? "Following" : "Listening…"
        case .offScript:
            status = "Off-script — holding"
        case .advance(let i), .jump(let i):
            // Moving to the next slide is routine; jumping somewhere else is a bigger claim, so it needs strong evidence.
            var isJump = false
            if case .jump = d.kind { isJump = true }
            if autoAdvance, !(isJump && d.confidence < 0.8) {
                engine.trigger(p, index: i)
                // Keep the last couple of words: they often begin the next line.
                consumedWords = max(0, words.count - 2)
                status = i == (current ?? -1) + 1 ? "Advanced" : "Jumped to \(p.orderedSlides[safe: i]?.groupName ?? "slide")"
            } else {
                status = "Suggest: slide \(i + 1)"
            }
        }
    }
}
