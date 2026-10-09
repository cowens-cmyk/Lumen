import XCTest
@testable import Lumen

@MainActor
final class LibrarySafetyTests: XCTestCase {
    private func write(_ lib: LibraryData, to dir: URL, name: String = "library.json") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.lumen.encode(lib).write(to: dir.appendingPathComponent(name))
    }

    func testDamagedLibraryComesBackFromTheNewestBackup() throws {
        let dir = tempFolder()
        var good = SeedData.make()
        good.presentations.append(Presentation(name: "My Precious Song", kind: .song))
        let backups = dir.appendingPathComponent("Backups")
        try write(good, to: backups, name: "daily-2026-10-01.json")
        // Today's library file is garbage (power cut mid-write, disk problem, anything)
        try Data("{\"presentations\": [ not json".utf8).write(to: dir.appendingPathComponent("library.json"))
        let store = LibraryStore(folder: dir)
        XCTAssertTrue(store.data.presentations.contains { $0.name == "My Precious Song" }, "must come back on the backup, not an empty library")
        XCTAssertEqual(store.restoredFromBackup, "daily-2026-10-01.json")
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(kept.contains { $0.hasPrefix("library-unreadable-") }, "the damaged file is kept for inspection")
    }

    func testOneUnreadableItemDoesNotCostTheRestOfTheLibrary() throws {
        let dir = tempFolder()
        var lib = SeedData.make()
        lib.presentations.append(Presentation(name: "Keep Me", kind: .song))
        try write(lib, to: dir)
        // Corrupt exactly one macro: an action from some future version this build doesn't know
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("library.json"))) as! [String: Any]
        var macros = json["macros"] as! [[String: Any]]
        macros[0]["actions"] = [["someFutureAction": ["_0": 1]]]
        json["macros"] = macros
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("library.json"))
        let store = LibraryStore(folder: dir)
        XCTAssertEqual(store.data.macros.count, lib.macros.count - 1, "only the unreadable macro is skipped")
        XCTAssertTrue(store.data.presentations.contains { $0.name == "Keep Me" }, "songs untouched")
        XCTAssertEqual(store.data.themes.count, lib.themes.count)
        XCTAssertNotNil(store.loadNotice)
        XCTAssertTrue(store.loadNotice?.contains("macros") == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("library-before-skipping-") }, "the original is preserved before anything is overwritten")
    }

    func testSettingsFromAnOlderVersionStillLoad() throws {
        // A settings object with only some keys (as an older build would have written)
        let old = Data("{\"bibleTranslation\":\"web\",\"remotePort\":9000}".utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(s.bibleTranslation, "web")
        XCTAssertEqual(s.remotePort, 9000)
        XCTAssertEqual(s.pcoSyncDaysAhead, 35, "missing keys fall back to their defaults")
        // And a wrong type for one key doesn't sink the others
        let weird = Data("{\"bibleTranslation\":\"web\",\"remotePort\":\"not a number\"}".utf8)
        let s2 = try JSONDecoder().decode(AppSettings.self, from: weird)
        XCTAssertEqual(s2.bibleTranslation, "web")
        XCTAssertEqual(s2.remotePort, 8090)
    }

    func testDailyBackupIsMadeOncePerDayAndPrunedByDate() throws {
        let dir = tempFolder()
        try write(SeedData.make(), to: dir)
        _ = LibraryStore(folder: dir)
        let backups = dir.appendingPathComponent("Backups")
        let first = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasPrefix("daily-") }
        XCTAssertEqual(first.count, 1)
        _ = LibraryStore(folder: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasPrefix("daily-") }.count, 1, "once per day")

        // Pruning goes by file date, not name: "1.10" must not beat "1.9"
        let pdir = tempFolder()
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for (i, name) in ["library-1.9-a.json", "library-1.10-b.json", "library-1.8-c.json"].enumerated() {
            let f = pdir.appendingPathComponent(name)
            try Data("x".utf8).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i) * 60)], ofItemAtPath: f.path)
        }
        LibraryStore.prune(pdir, prefix: "library-", keep: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pdir.path), ["library-1.8-c.json"], "newest by date survives")
    }

    func testMissingFolderStartsFreshWithSeed() {
        let store = LibraryStore(folder: tempFolder())
        XCTAssertFalse(store.data.themes.isEmpty)
        XCTAssertFalse(store.data.screens.isEmpty)
        XCTAssertNil(store.restoredFromBackup)
    }

    func testImportKeepsGoingPastABadFile() async throws {
        let store = LibraryStore(folder: tempFolder())
        let dir = tempFolder(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("Song.txt"); try "Amazing Song\n\nVerse 1\nline one\nline two".write(to: good, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("weird.txt"); try Data([0xff, 0xfe, 0xfd, 0x00, 0xc3, 0x28]).write(to: bad)
        let unsupported = dir.appendingPathComponent("thing.xyz"); try Data("x".utf8).write(to: unsupported)
        let r = try await Importer(store: store).importFiles([bad, good, unsupported])
        XCTAssertEqual(r.presentations.count, 1, "the good song still imports")
        XCTAssertEqual(r.failures.count, 2, "the bad ones are reported, not fatal: \(r.failures)")
    }
}

@MainActor
final class RecoveryTests: XCTestCase {
    func testSnapshotRecoverability() {
        let now = Date()
        let id = UUID()
        XCTAssertTrue(SessionSnapshot(cleanExit: false, presentationID: id, index: 2, savedAt: now.addingTimeInterval(-60)).isRecoverable(now: now))
        XCTAssertFalse(SessionSnapshot(cleanExit: true, presentationID: id, index: 2, savedAt: now).isRecoverable(now: now), "quit normally")
        XCTAssertFalse(SessionSnapshot(cleanExit: false, presentationID: nil, index: nil, savedAt: now).isRecoverable(now: now), "nothing was live")
        XCTAssertFalse(SessionSnapshot(cleanExit: false, presentationID: id, index: 2, savedAt: now.addingTimeInterval(-9 * 3600)).isRecoverable(now: now), "yesterday's session")
    }

    func testCrashedSessionOffersToPutTheSlideBack() throws {
        let dir = tempFolder()
        let store = LibraryStore(folder: dir)
        var song = Presentation(name: "Live Song", kind: .song)
        song.groups = [SlideGroup(name: "V", color: .black, slides: [Slide(text: "a"), Slide(text: "b"), Slide(text: "c")])]
        store.upsert(song); store.saveNow()
        // A previous run that was live on slide 3 and never quit cleanly
        SessionSnapshot(cleanExit: false, presentationID: song.id, presentationName: song.name, index: 2, playlistID: nil,
                        lookID: store.data.looks[1].id, savedAt: Date()).save(to: dir)
        let app = AppModel(libraryFolder: dir)
        XCTAssertEqual(app.recovery?.presentationName, "Live Song")
        XCTAssertNil(app.engine.livePresentationID, "never put an old slide on the outputs without being asked")
        app.restoreSession()
        XCTAssertEqual(app.engine.livePresentationID, song.id)
        XCTAssertEqual(app.engine.liveIndex, 2)
        XCTAssertEqual(app.engine.lookID, store.data.looks[1].id, "and the look it was in")
        XCTAssertNil(app.recovery)
    }

    func testCleanQuitOffersNothing() throws {
        let dir = tempFolder()
        let store = LibraryStore(folder: dir); store.saveNow()
        let app1 = AppModel(libraryFolder: dir)
        app1.shutdown()
        XCTAssertNil(AppModel(libraryFolder: dir).recovery)
    }

    func testLiveMarkerFileFollowsTheOutputs() async throws {
        let dir = tempFolder()
        let app = AppModel(libraryFolder: dir)
        var p = Presentation(name: "S", kind: .song)
        p.groups = [SlideGroup(name: "V", color: .black, slides: [Slide(text: "x")])]
        app.store.upsert(p)
        let marker = dir.appendingPathComponent("live")
        app.engine.trigger(p, index: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "update.sh waits while this exists")
        app.engine.clear(.all)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

@MainActor
final class SchedulingSafetyTests: XCTestCase {
    private func date(_ s: String, tz: String = "America/New_York") -> Date {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: tz); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    func testOnTimeTriggerFiresAndAStaleOneIsSkipped() {
        let t = date("2026-10-11 09:30:00")
        let once = ScheduleWhen.once(t)
        XCTAssertEqual(Scheduler.due(once, since: t.addingTimeInterval(-1), now: t.addingTimeInterval(0.5)), .fire(t))
        XCTAssertEqual(Scheduler.due(once, since: t.addingTimeInterval(-1), now: t.addingTimeInterval(60)), .fire(t), "a little late is fine")
        // The Mac slept through 9:30 and woke at noon: the walk-in macro must not fire now.
        XCTAssertEqual(Scheduler.due(once, since: t.addingTimeInterval(-600), now: t.addingTimeInterval(2.5 * 3600)), .missed(t))
        XCTAssertEqual(Scheduler.due(once, since: t.addingTimeInterval(1), now: t.addingTimeInterval(5)), .none, "already past, not re-fired")
    }

    func testWeeklyTriggerAcrossDaylightSavingChange() {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = saved }
        // US clocks spring forward on Sunday 8 March 2026 at 2:00. A Sunday 10:30 trigger must still be 10:30 local.
        let weekly = ScheduleWhen.weekly(weekday: 1, hour: 10, minute: 30)
        let since = date("2026-03-08 10:29:59"), now = date("2026-03-08 10:30:01")
        XCTAssertEqual(Scheduler.due(weekly, since: since, now: now), .fire(date("2026-03-08 10:30:00")))
        // …and a week earlier (standard time) too
        XCTAssertEqual(Scheduler.due(weekly, since: date("2026-03-01 10:29:59"), now: date("2026-03-01 10:30:01")), .fire(date("2026-03-01 10:30:00")))
        // Not due the minute before
        XCTAssertEqual(Scheduler.due(weekly, since: date("2026-03-08 10:28:00"), now: date("2026-03-08 10:29:00")), .none)
    }

    func testCountdownToClockTimeAcrossMidnightAndAfterTheTime() {
        let timer = ServiceTimer(name: "Service", kind: .countdownTo(hour: 10, minute: 30))
        let rt = TimerRuntime()
        // 9:00 → 1:30 to go
        XCTAssertEqual(rt.value(for: timer, at: date("2026-10-11 09:00:00")), 5400, accuracy: 1)
        // 10:35 → five minutes over, shown as negative (not "tomorrow")
        XCTAssertEqual(rt.value(for: timer, at: date("2026-10-11 10:35:00")), -300, accuracy: 1)
        // 23:00 → counts to tomorrow 10:30 (11.5 h)
        XCTAssertEqual(rt.value(for: timer, at: date("2026-10-11 23:00:00")), 11.5 * 3600, accuracy: 1)
        XCTAssertEqual(TimerRuntime.format(-300), "-5:00")
    }
}

@MainActor
final class OutputSafetyTests: XCTestCase {
    func testOutputIsNeverPutOnTheOperatorsOwnDisplay() throws {
        UserDefaults.standard.removeObject(forKey: "allowOutputOnOperatorDisplay")
        let store = LibraryStore(folder: tempFolder())
        let engine = LiveEngine(store: store)
        engine.media = MediaEngine(); engine.capture = CaptureManager(); engine.browser = BrowserController()
        engine.ndiIn = NDIReceiveManager(); engine.midi = MIDIManager()
        let outputs = OutputManager(store: store, engine: engine)
        let main = try XCTUnwrap(NSScreen.screens.first)
        store.data.screens[0].destinations = [.display(id: main.displayID, name: main.localizedName)]
        outputs.rebuild()
        let status = outputs.statusByScreen[store.data.screens[0].id]?.joined() ?? ""
        XCTAssertTrue(status.contains("Skipped"), "on a one-display Mac the only display is the operator's: \(status)")
        outputs.renderers.values.forEach { $0.stop() }
    }

    func testDisplayChangeRedoesOnlyDisplayWindowsAndKeepsOtherSinks() throws {
        let store = LibraryStore(folder: tempFolder())
        let engine = LiveEngine(store: store)
        engine.media = MediaEngine(); engine.capture = CaptureManager(); engine.browser = BrowserController()
        engine.ndiIn = NDIReceiveManager(); engine.midi = MIDIManager()
        let outputs = OutputManager(store: store, engine: engine)
        store.data.screens[1].destinations = [.window]       // stands in for DeckLink/NDI: a sink that must survive
        outputs.rebuild()
        let id = store.data.screens[1].id
        let renderer = try XCTUnwrap(outputs.renderers[id])
        let custom = CaptureSink()
        renderer.addSink(custom)
        let before = renderer.sinkCount
        outputs.refreshDisplays()                              // what a projector re-handshake triggers
        XCTAssertEqual(renderer.sinkCount, before, "non-display sinks (DeckLink, NDI, windows) keep running untouched")
        XCTAssertTrue(outputs.renderers[id] === renderer, "same renderer: no teardown")
        outputs.renderers.values.forEach { $0.stop() }
    }

    func testRenderHealthReportsTheRealFrameRate() async throws {
        let r = ScreenRenderer(screenID: UUID(), size: CGSize(width: 1280, height: 720), fps: 30)
        r.update(ScreenScene())
        r.start()
        try await Task.sleep(for: .seconds(2.2))
        let h = r.health
        r.stop()
        XCTAssertGreaterThan(h.totalFrames, 40)
        XCTAssertEqual(h.fps, 30, accuracy: 4, "measured rate should be close to the target")
        XCTAssertTrue(h.isHealthy)
        XCTAssertLessThan(h.avgMs, 33, "rendering must fit inside one frame")
    }
}
