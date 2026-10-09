import AVFoundation
import XCTest
@testable import Lumen

@MainActor
final class EngineHardeningTests: XCTestCase {
    private func make() -> (LiveEngine, LibraryStore) {
        let store = LibraryStore(folder: tempFolder())
        let engine = LiveEngine(store: store)
        engine.media = MediaEngine()
        engine.capture = CaptureManager(); engine.browser = BrowserController()
        engine.ndiIn = NDIReceiveManager(); engine.midi = MIDIManager()
        return (engine, store)
    }

    private func song(_ name: String, slides n: Int) -> Presentation {
        var p = Presentation(name: name, kind: .song)
        p.groups = [SlideGroup(name: "Verse 1", color: .black, slides: (1...n).map { Slide(text: "\(name) line \($0)") })]
        return p
    }

    // MARK: slideshow (review #2)

    func testSlideshowStopsWhenSomethingElseGoesLive() async throws {
        let (engine, store) = make()
        var loop = song("Announcements", slides: 5); loop.slideshow = SlideshowSettings(enabled: true, interval: 0.5, loop: true)
        let worship = song("Worship", slides: 4)
        store.upsert(loop); store.upsert(worship)
        engine.trigger(loop, index: 0)
        XCTAssertNotNil(engine.slideshowInterval)
        engine.trigger(worship, index: 0)
        XCTAssertNil(engine.slideshowInterval, "a slideshow must not outlive its presentation")
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(engine.livePresentationID, worship.id)
        XCTAssertEqual(engine.liveIndex, 0, "the song must not advance by itself")
    }

    func testClearSlideHoldsEvenDuringASlideshow() async throws {
        let (engine, store) = make()
        var loop = song("Loop", slides: 3); loop.slideshow = SlideshowSettings(enabled: true, interval: 0.5, loop: true)
        store.upsert(loop)
        engine.trigger(loop, index: 0)
        engine.clear(.slide)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertTrue(engine.slideCleared, "F1 must hold; the slideshow may not re-show slide 1")
        XCTAssertNil(engine.currentSlide)
    }

    func testSlideshowStillAdvancesItsOwnPresentation() async throws {
        let (engine, store) = make()
        var loop = song("Loop", slides: 4); loop.slideshow = SlideshowSettings(enabled: true, interval: 0.5, loop: true)
        store.upsert(loop)
        engine.trigger(loop, index: 0)
        try await Task.sleep(for: .seconds(1.8))
        XCTAssertGreaterThan(engine.liveIndex ?? 0, 0)
        engine.stopSlideshow()
    }

    // MARK: never blank (review #12/#18)

    func testEditingTheLiveSongNeverBlanksTheScreen() {
        let (engine, store) = make()
        var p = song("Song", slides: 4)
        store.upsert(p)
        engine.trigger(p, index: 3)
        XCTAssertEqual(engine.currentSlide?.slide.text, "Song line 4")
        // The operator deletes slides from the live song and saves
        p.groups[0].slides.removeLast(2)
        store.upsert(p)
        XCTAssertNotNil(engine.currentSlide, "screen keeps showing what it was showing")
        XCTAssertEqual(engine.currentSlide?.slide.text, "Song line 4")
        // Follows an edit to the live slide's own text
        p = store.presentation(p.id)!
        p.groups[0].slides[1].text = "edited"
        store.upsert(p)
        // Deleting the whole song underneath it
        store.data.presentations.removeAll { $0.id == p.id }
        XCTAssertNotNil(engine.currentSlide)
        engine.next(); engine.previous()      // must not crash with nothing behind them
        XCTAssertNotNil(engine.currentSlide)
    }

    func testLiveSlideFollowsItsContentWhenSlidesAreReordered() {
        let (engine, store) = make()
        var p = song("Song", slides: 3)
        store.upsert(p)
        engine.trigger(p, index: 2)                       // "Song line 3"
        p.groups[0].slides.insert(Slide(text: "new first"), at: 0)
        store.upsert(p)
        XCTAssertEqual(engine.currentSlide?.slide.text, "Song line 3", "still the slide the room is seeing")
        XCTAssertEqual(engine.resolvedIndex, 3)
        engine.next()
        XCTAssertNil(store.presentation(p.id).flatMap { _ in engine.currentSlide == nil ? 1 : nil }, "next from the end stays safe")
    }

    func testRepeatedChorusDoesNotJumpBackToFirstOccurrence() {
        let (engine, store) = make()
        var p = Presentation(name: "Song", kind: .song)
        let verse = SlideGroup(name: "Verse", color: .black, slides: [Slide(text: "verse")])
        let chorus = SlideGroup(name: "Chorus", color: .black, slides: [Slide(text: "chorus")])
        p.groups = [verse, chorus]
        p.arrangement = [verse.id, chorus.id, verse.id, chorus.id]
        store.upsert(p)
        engine.trigger(p, index: 3)                       // second chorus
        XCTAssertEqual(engine.resolvedIndex, 3, "same slide id appears twice; the position must win")
        engine.previous()
        XCTAssertEqual(engine.liveIndex, 2)
    }

    // MARK: media lifecycle (review #8/#9)

    func testSwitchingMediaStopsThePreviousVideo() async throws {
        let (engine, _) = make()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        try makeVideo(at: url, seconds: 3)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("pic-\(UUID().uuidString).png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!.write(to: png)
        engine.playMedia(MediaRef(kind: .video, location: url.path, loop: false))
        XCTAssertTrue(engine.media.isPlaying)
        engine.playMedia(MediaRef(kind: .image, location: png.path))
        XCTAssertFalse(engine.media.isPlaying, "the old video must not keep playing (or making sound) under the new picture")
        XCTAssertEqual(engine.mediaLayer?.kind, .image)
        engine.clear(.media)
        XCTAssertNil(engine.mediaLayer)
    }

    func testMissingMediaFileKeepsWhatIsOnScreenAndSaysSo() {
        let (engine, _) = make()
        var problem: String?
        engine.onProblem = { problem = $0 }
        let good = FileManager.default.temporaryDirectory.appendingPathComponent("pic-\(UUID().uuidString).png")
        try? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!.write(to: good)
        engine.playMedia(MediaRef(kind: .image, location: good.path))
        engine.playMedia(MediaRef(kind: .video, location: "/nonexistent/video.mov"))
        XCTAssertEqual(engine.mediaLayer?.location, good.path, "a missing file must not replace the picture with a stale frame")
        XCTAssertTrue(problem?.contains("Can't find") == true, problem ?? "no message")
    }

    func testStaleLiveSourcesDisappearButPlayersAndWebHold() async throws {
        let old = LiveFrames.staleAfter
        LiveFrames.staleAfter = 0.3
        defer { LiveFrames.staleAfter = old }
        let img = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        LiveFrames.shared.set("capture:cam1", img)
        LiveFrames.shared.set("ndi:src", img)
        LiveFrames.shared.set(LiveFrames.videoKey, img)
        LiveFrames.shared.set(LiveFrames.webKey, img)
        XCTAssertNotNil(LiveFrames.shared.get("capture:cam1"))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(LiveFrames.shared.get("capture:cam1"), "an unplugged capture card must not leave a frozen frame up")
        XCTAssertNil(LiveFrames.shared.get("ndi:src"))
        XCTAssertNotNil(LiveFrames.shared.get(LiveFrames.videoKey), "a paused video legitimately holds its frame")
        XCTAssertNotNil(LiveFrames.shared.get(LiveFrames.webKey), "a still web page sends no new frames")
        for k in [LiveFrames.videoKey, LiveFrames.webKey] { LiveFrames.shared.set(k, nil) }
    }

    // MARK: actions (review #19)

    func testClearAllCancelsDelayedActions() async throws {
        let (engine, _) = make()
        engine.run([.delay(0.4), .showMessage("too late")])
        engine.clear(.all)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(engine.message, "a macro's delayed steps must not fire after Clear All")
    }

    func testRunawaySlideActionIsStopped() async throws {
        let (engine, store) = make()
        var p = song("Loopy", slides: 1)
        p.groups[0].slides[0].actions = [.triggerPresentation(p.id, slide: 0)]
        store.upsert(p)
        var problems = 0
        engine.onProblem = { _ in problems += 1 }
        var triggers = 0
        engine.onSlideTriggered = { _, _ in triggers += 1 }
        engine.trigger(p, index: 0)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertGreaterThan(problems, 0, "operator is told")
        XCTAssertLessThan(triggers, 60, "a self-triggering action must be cut off, not spin forever (got \(triggers))")
    }

    // MARK: random operations

    func testRandomOperationsNeverBreakInvariants() async throws {
        let (engine, store) = make()
        var pres: [Presentation] = (1...4).map { song("S\($0)", slides: $0 + 1) }
        pres.forEach(store.upsert)
        let pl = Playlist(name: "P", items: pres.map { PlaylistItem(kind: .presentation($0.id)) })
        store.upsert(pl)
        var rng = SplitMix(seed: 42)
        for step in 0..<3000 {
            switch rng.next(14) {
            case 0, 1, 2: let p = pres[rng.next(pres.count)]; engine.trigger(p, index: rng.next(p.orderedSlides.count + 1) , playlistID: rng.next(2) == 0 ? pl.id : nil)
            case 3, 4: engine.next()
            case 5: engine.previous()
            case 6: engine.clear([.slide, .media, .props, .messages, .all][rng.next(5)])
            case 7: if let l = store.data.looks.randomElement() { engine.setLook(l.id) }
            case 8: if let pr = store.data.props.randomElement() { engine.toggleProp(pr.id) }
            case 9: if let t = store.data.timers.randomElement() { [engine.startTimer, engine.stopTimer, engine.resetTimer][rng.next(3)](t.id) }
            case 10:   // edit the live presentation: shrink or grow it
                if let id = engine.livePresentationID, var p = store.presentation(id) {
                    let n = max(1, rng.next(5)); p.groups[0].slides = (0..<n).map { Slide(text: "e\($0)") }; store.upsert(p)
                }
            case 11: engine.showMessage(rng.next(2) == 0 ? "hello" : nil)
            case 12: if rng.next(10) == 0, let id = engine.livePresentationID { store.data.presentations.removeAll { $0.id == id } }
            default: engine.stopSlideshow()
            }
            // Invariants
            if !engine.slideCleared, engine.liveIndex != nil {
                XCTAssertNotNil(engine.currentSlide, "step \(step): something is meant to be live but the screen would be blank")
            }
            if let i = engine.resolvedIndex { XCTAssertTrue(engine.liveSlides.indices.contains(i), "step \(step)") }
            XCTAssertGreaterThanOrEqual(engine.revision, 0)
            if step % 100 == 0 { pres = store.data.presentations.filter { p in pres.contains { $0.id == p.id } }; if pres.isEmpty { pres = [song("R", slides: 3)]; store.upsert(pres[0]) } }
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ n: Int) -> Int { n <= 0 ? 0 : Int(next64() % UInt64(n)) }
}
