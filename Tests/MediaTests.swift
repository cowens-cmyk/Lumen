import AVFoundation
import CoreImage
import XCTest
@testable import Lumen

/// Collects the renderer's output so tests can look at real pixels.
final class CaptureSink: FrameSink {
    func send(_ buffer: CVPixelBuffer) {}
    func stop() {}
}

func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let o = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (Int(base[o + 2]), Int(base[o + 1]), Int(base[o]), Int(base[o + 3]))   // BGRA
}

/// Writes a small H.264 clip whose colour changes every frame.
func makeVideo(at url: URL, seconds: Double = 2, width: Int = 320, height: Int = 180, fps: Int32 = 30) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<Int(seconds * Double(fps)) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
        for p in 0..<(width * height) {
            base[p * 4] = UInt8((i * 8) % 256); base[p * 4 + 1] = 120; base[p * 4 + 2] = 200; base[p * 4 + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "makeVideo", code: 1) }
}

final class LetterboxTests: XCTestCase {
    private func render(media: SceneBackground, theme: SceneBackground = .color(RGBA(r: 0, g: 0, b: 1)), opaque: Bool = true) throws -> CVPixelBuffer {
        let r = ScreenRenderer(screenID: UUID(), size: CGSize(width: 1920, height: 1080), fps: 30)
        var scene = ScreenScene()
        scene.themeBackground = theme       // blue by default: must never show around a fit picture
        scene.media = media
        scene.opaque = opaque
        scene.transition = 0
        r.update(scene)
        r.start()
        defer { r.stop() }
        let deadline = Date().addingTimeInterval(5)
        while r.latestFrame == nil, Date() < deadline { usleep(20_000) }
        usleep(150_000)   // let the frame with this scene replace any earlier one
        return try XCTUnwrap(r.latestFrame)
    }

    private var red228x400: CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 228, height: 400))
    }

    /// Your example: a 228×400 image on a 1920×1080 screen fills the height and sits on black.
    func testTallImageFitsToHeightWithBlackBars() throws {
        let f = try render(media: .image(red228x400, .fit))
        // 228×400 scaled to 1080 tall is 615 wide, centred: x ≈ 652…1268
        XCTAssertEqual(pixel(f, 960, 540).r, 255, accuracy: 3, "picture in the middle")
        XCTAssertEqual(pixel(f, 960, 2).r, 255, accuracy: 3, "touches the top")
        XCTAssertEqual(pixel(f, 960, 1077).r, 255, accuracy: 3, "touches the bottom")
        for x in [10, 400, 640, 1280, 1500, 1910] {
            let p = pixel(f, x, 540)
            XCTAssertEqual([p.r, p.g, p.b], [0, 0, 0], "x=\(x) must be pure black, not the blue theme color")
        }
        XCTAssertEqual(pixel(f, 660, 540).r, 255, accuracy: 3, "just inside the left edge of the picture")
        XCTAssertEqual(pixel(f, 1260, 540).r, 255, accuracy: 3, "just inside the right edge")
    }

    func testWideImageGetsBarsTopAndBottom() throws {
        let wide = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 200))
        let f = try render(media: .image(wide, .fit))
        XCTAssertEqual(pixel(f, 960, 540).g, 255, accuracy: 3)
        XCTAssertEqual(pixel(f, 5, 540).g, 255, accuracy: 3, "touches left")
        XCTAssertEqual(pixel(f, 1914, 540).g, 255, accuracy: 3, "touches right")
        let top = pixel(f, 960, 20), bottom = pixel(f, 960, 1060)
        XCTAssertEqual([top.r, top.g, top.b, bottom.r, bottom.g, bottom.b], [0, 0, 0, 0, 0, 0])
    }

    func testFillCropsInsteadOfBars() throws {
        let f = try render(media: .image(red228x400, .fill))
        XCTAssertEqual(pixel(f, 10, 540).r, 255, accuracy: 3)
        XCTAssertEqual(pixel(f, 1910, 10).r, 255, accuracy: 3)
    }

    func testExactScreenShapeHasNoBars() throws {
        let hd = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let f = try render(media: .image(hd, .fit), theme: .color(RGBA(r: 1, g: 0, b: 0)))
        XCTAssertEqual(pixel(f, 2, 2).b, 255, accuracy: 3)
        XCTAssertEqual(pixel(f, 1917, 1077).b, 255, accuracy: 3)
    }

    func testKeyedOutputKeepsMarginsTransparent() throws {
        // A keyed output (lower third mode) has no theme background behind it, so margins stay transparent.
        let f = try render(media: .image(red228x400, .fit), theme: .none, opaque: false)
        XCTAssertEqual(pixel(f, 100, 540).a, 0, "margins stay see-through over the camera")
        XCTAssertEqual(pixel(f, 960, 540).a, 255, accuracy: 3)
    }
}

@MainActor
final class BackgroundLoopTests: XCTestCase {
    func testLoopsSeamlesslyPastTheEndOfTheClip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString).mov")
        try makeVideo(at: url, seconds: 2)
        let media = MediaEngine()
        let ref = MediaRef(kind: .video, location: url.path)
        media.setBackground(ref)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertNotNil(LiveFrames.shared.get(LiveFrames.backgroundKey), "frames arrive")
        let early = media.backgroundFrameCount
        XCTAssertGreaterThan(early, 5)
        try await Task.sleep(for: .seconds(3))                     // well past the 2 s clip
        // A clip that didn't loop would add ~25 more frames; looping keeps delivering ~30/s.
        XCTAssertGreaterThan(media.backgroundFrameCount, early + 50, "loop must keep running after the clip ends")
        media.setBackground(ref)                                   // same file: must not restart
        XCTAssertEqual(media.backgroundLocation, url.path)
        media.setBackground(nil)
        XCTAssertNil(media.backgroundLocation)
        XCTAssertNil(LiveFrames.shared.get(LiveFrames.backgroundKey))
    }

    func testEngineKeepsLoopAcrossSlidesAndStopsWhenCleared() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("song-\(UUID().uuidString).mov")
        try makeVideo(at: url, seconds: 2)
        let store = LibraryStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let engine = LiveEngine(store: store)
        engine.media = MediaEngine()
        engine.capture = CaptureManager(); engine.browser = BrowserController()
        engine.ndiIn = NDIReceiveManager(); engine.midi = MIDIManager()
        var song = LyricParser.presentation(name: "Loop Song", text: "[Verse 1]\nLine one\nLine two\n\nLine three\nLine four", maxLines: 2)
        song.background = MediaRef(kind: .video, location: url.path)
        store.upsert(song)

        engine.trigger(song, index: 0)
        XCTAssertEqual(engine.media.backgroundLocation, url.path)
        try await Task.sleep(for: .seconds(0.8))
        let frames = engine.media.backgroundFrameCount
        XCTAssertGreaterThan(frames, 3)
        engine.trigger(song, index: 1)                              // next slide, same loop: no restart
        XCTAssertGreaterThanOrEqual(engine.media.backgroundFrameCount, frames, "frame counter would reset on a restart")

        // The output sees the live loop behind the words.
        let outputs = OutputManager(store: store, engine: engine)
        let audience = try XCTUnwrap(store.data.screens.first { $0.role == .audience })
        guard case .live(let key, _) = outputs.scene(for: audience, size: CGSize(width: 1920, height: 1080)).themeBackground else {
            return XCTFail("expected the live background loop")
        }
        XCTAssertEqual(key, LiveFrames.backgroundKey)

        engine.clear(.slide)
        XCTAssertNil(engine.media.backgroundLocation, "loop stops with the slide")
    }
}
