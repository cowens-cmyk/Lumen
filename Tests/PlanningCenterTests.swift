import XCTest
@testable import Lumen

/// Replays a service shaped exactly like a real Hope Church plan (item types "header" / "item" / "song",
/// COUNTDOWN and MESSAGE headers, keys like "Bb-C", JSON nulls) without touching the network.
@MainActor
final class PlanningCenterSyncTests: XCTestCase {
    typealias R = PlanningCenterClient.Resource

    private func item(_ id: String, _ seq: Int, _ type: String, _ title: String, desc: Any = NSNull(), key: Any = NSNull(),
                      song: String? = nil, arr: String? = nil) -> R {
        func rel(_ type: String, _ id: String?) -> [String: Any] { ["data": id.map { ["type": type, "id": $0] as [String: Any] } ?? NSNull()] }
        return R(id: id, type: "Item",
                 attributes: ["title": title, "item_type": type, "description": desc, "key_name": key, "sequence": seq,
                              "length": 0, "custom_arrangement_sequence": NSNull()],
                 relationships: ["song": rel("Song", song), "arrangement": rel("Arrangement", arr), "key": rel("Key", nil)])
    }

    private func song(_ id: String, _ title: String, ccli: Any) -> R {
        R(id: id, type: "Song", attributes: ["title": title, "author": "Some Writer", "ccli_number": ccli, "copyright": NSNull()], relationships: [:])
    }

    private func arrangement(_ id: String, _ name: String, lyrics: String?, sequence: [String]? = nil, updated: String = "2026-09-30T10:00:00Z",
                             chartKey: Any = NSNull()) -> R {
        R(id: id, type: "Arrangement",
          attributes: ["name": name, "lyrics": lyrics ?? NSNull(), "sequence": sequence ?? NSNull(), "chord_chart_key": chartKey,
                       "chord_chart": NSNull(), "updated_at": updated],
          relationships: [:])
    }

    private let lyricsA = "Verse 1\nFirst line of verse\nSecond line of verse\n\nChorus\nChorus line one\nChorus line two"

    private func page(songLyrics: String? = nil, updated: String = "2026-09-30T10:00:00Z") -> PlanningCenterClient.Page {
        .init(data: [
            item("1", 1, "header", "COUNTDOWN"),
            item("2", 2, "header", "OPENING SONG"),
            item("3", 3, "song", "The Lord Will Provide", desc: "Cameron, Lydia\nStarting with the intro", key: "Bb-C", song: "s1", arr: "a1"),
            item("4", 4, "item", "Announcements", desc: "Logan Harris"),
            item("5", 5, "header", "WORSHIP"),
            item("6", 6, "song", "Center (Live)", key: "A", song: "s2", arr: "a2"),
            item("7", 7, "song", "No Lyrics Song", key: "G", song: "s3", arr: "a3"),
            item("8", 8, "header", "MESSAGE"),
            item("9", 9, "item", "Genesis 29", desc: "Rick Keller"),
            item("10", 10, "header", "CLOSING SONG"),
            item("11", 11, "item", "Close", desc: "Rick Keller"),
        ], included: [
            song("s1", "The Lord Will Provide", ccli: 7227727), arrangement("a1", "Passion (Spicy Version)", lyrics: songLyrics ?? lyricsA, sequence: ["Verse 1", "Chorus", "Chorus"], updated: updated),
            song("s2", "Center (Live)", ccli: NSNull()), arrangement("a2", "Bethel Music", lyrics: lyricsA),
            song("s3", "No Lyrics Song", ccli: 1), arrangement("a3", "Default Arrangement", lyrics: nil),
        ])
    }

    private func makeSync(_ page: (@MainActor () -> PlanningCenterClient.Page)? = nil)
        throws -> (PlanningCenterSync, LibraryStore) {
        let provide: @MainActor () -> PlanningCenterClient.Page = page ?? { [unowned self] in self.page() }
        let store = LibraryStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.data.settings.pcoAppID = "app"
        store.data.settings.pcoServiceTypeIDs = ["1212625"]
        let sync = PlanningCenterSync(store: store, scripture: ScriptureService(store: store))
        let plan = R(id: "P1", type: "Plan", attributes: ["sort_date": "2026-10-04T07:30:00Z", "updated_at": "2026-09-30T19:30:16Z",
                                                          "title": NSNull(), "dates": "October 4, 2026"], relationships: [:])
        sync.plansOverride = { _ in [plan] }
        sync.itemsOverride = { _, _ in await provide() }
        return (sync, store)
    }

    private func names(_ store: LibraryStore) -> [String] {
        store.data.playlists.first?.items.map { i -> String in
            switch i.kind {
            case .header(let t): "§ " + t
            case .placeholder(let t): "? " + t
            case .presentation(let id): "▶ " + (store.presentation(id)?.name ?? "MISSING")
            }
        } ?? []
    }

    func testRealShapedServiceMapsEveryItem() async throws {
        let (sync, store) = try makeSync()
        let ok = await sync.sync()
        XCTAssertTrue(ok, sync.lastError ?? "")
        XCTAssertEqual(names(store), [
            "§ COUNTDOWN", "▶ Countdown",                       // the empty COUNTDOWN header becomes your countdown video slot
            "§ OPENING SONG", "▶ The Lord Will Provide (Passion (Spicy Version))",
            "▶ Announcements",
            "§ WORSHIP", "▶ Center (Live) (Bethel Music)", "? No Lyrics Song — no lyrics in Planning Center",
            "§ MESSAGE", "▶ Sermon",                            // "Genesis 29" sits under MESSAGE → sermon slides
            "§ CLOSING SONG", "? Close",
        ])
        let lord = try XCTUnwrap(store.data.presentations.first { $0.name.hasPrefix("The Lord Will Provide") })
        XCTAssertEqual(lord.ccli, "7227727")
        XCTAssertEqual(lord.author, "Some Writer")
        XCTAssertEqual(lord.orderedSlides.map(\.groupName), ["Verse 1", "Chorus", "Chorus"], "arrangement order from Planning Center")
        let center = try XCTUnwrap(store.data.presentations.first { $0.name.hasPrefix("Center") })
        XCTAssertEqual(center.ccli, "", "a null CCLI number must not become the text “<null>”")
        XCTAssertEqual(center.copyright, "")
        let countdown = try XCTUnwrap(store.data.presentations.first { $0.name == "Countdown" })
        XCTAssertEqual(countdown.kind, .media)
        // Band notes ride along for the stage display
        let first = store.data.playlists[0].items.first { if case .presentation(let id) = $0.kind { id == lord.id } else { false } }
        XCTAssertEqual(first?.note?.components(separatedBy: "\n").first, "Cameron, Lydia")
        XCTAssertEqual(store.data.playlists[0].name, "Sun Oct 4")
    }

    func testResyncIsStableAndKeepsRowIdentity() async throws {
        let (sync, store) = try makeSync()
        _ = await sync.sync()
        let before = store.data.playlists[0].items
        _ = await sync.sync()
        XCTAssertEqual(store.data.playlists.count, 1)
        XCTAssertEqual(store.data.playlists[0].items, before, "nothing changed in Planning Center, so nothing changes here")
    }

    func testManualItemsSurviveSync() async throws {
        let (sync, store) = try makeSync()
        _ = await sync.sync()
        let video = Presentation(name: "Baptism Video", kind: .media)
        store.upsert(video)
        var pl = store.data.playlists[0]
        // The operator drops a video in after the announcements
        let idx = pl.items.firstIndex { if case .presentation(let id) = $0.kind { store.presentation(id)?.name == "Announcements" } else { false } }! + 1
        pl.items.insert(PlaylistItem(kind: .presentation(video.id)), at: idx)
        store.upsert(pl)
        _ = await sync.sync()
        XCTAssertTrue(names(store).contains("▶ Baptism Video"))
        let n = names(store)
        XCTAssertEqual(n[n.firstIndex(of: "▶ Announcements")! + 1], "▶ Baptism Video", "stays where the operator put it")
        XCTAssertEqual(n.filter { $0 == "▶ Baptism Video" }.count, 1, "never duplicated")
    }

    func testLockedPlaylistIsNeverTouched() async throws {
        var current = page()
        let (sync, store) = try makeSync { current }
        _ = await sync.sync()
        store.data.playlists[0].syncLocked = true
        let before = store.data.playlists[0].items
        current = .init(data: Array(current.data.prefix(4)), included: current.included)   // plan changed in Planning Center
        _ = await sync.sync()
        XCTAssertEqual(store.data.playlists[0].items, before)
    }

    func testNothingSyncsWhileLive() async throws {
        let (sync, store) = try makeSync()
        sync.isLive = { true }
        let ok = await sync.sync()
        XCTAssertFalse(ok)
        XCTAssertTrue(store.data.playlists.isEmpty)
        XCTAssertNotNil(sync.lastError)
        sync.isLive = { false }
        let ok2 = await sync.sync()
        XCTAssertTrue(ok2)
        XCTAssertFalse(store.data.playlists.isEmpty)
    }

    func testFailedSyncChangesNothing() async throws {
        let (sync, store) = try makeSync()
        _ = await sync.sync()
        let before = store.data.playlists
        sync.itemsOverride = { _, _ in throw URLError(.notConnectedToInternet) }
        let ok = await sync.sync()
        XCTAssertFalse(ok)
        XCTAssertEqual(store.data.playlists, before, "offline on Sunday morning: last good plan stays")
        XCTAssertNotNil(sync.lastError)
    }

    func testLyricChangeInPlanningCenterUpdatesSlidesUnlessLocked() async throws {
        var current = page()
        let (sync, store) = try makeSync { current }
        _ = await sync.sync()
        let new = "Verse 1\nBrand new first line\nSecond line of verse\n\nChorus\nChorus line one\nChorus line two"
        current = page(songLyrics: new, updated: "2026-10-02T10:00:00Z")
        _ = await sync.sync()
        var lord = try XCTUnwrap(store.data.presentations.first { $0.name.hasPrefix("The Lord Will Provide") })
        XCTAssertTrue(lord.groups[0].slides[0].text.contains("Brand new first line"))
        // Operator keeps their own edit
        lord.lockedFromSync = true
        lord.groups[0].slides[0].text = "My fixed lyric"
        store.upsert(lord)
        current = page(songLyrics: lyricsA, updated: "2026-10-03T10:00:00Z")
        _ = await sync.sync()
        let kept = try XCTUnwrap(store.presentation(lord.id))
        XCTAssertEqual(kept.groups[0].slides[0].text, "My fixed lyric")
    }

    func testPreviewReportsAndChangesNothing() async throws {
        let (sync, store) = try makeSync()
        let report = await sync.previewNextPlan().joined(separator: "\n")
        XCTAssertTrue(store.data.playlists.isEmpty)
        XCTAssertNil(store.data.presentations.first { $0.name == "Countdown" }, "dry run must not create anything")
        XCTAssertTrue(report.contains("COUNTDOWN"))
        XCTAssertTrue(report.contains("“Countdown” (will be created empty"))
        XCTAssertTrue(report.contains("The Lord Will Provide"))
        XCTAssertTrue(report.contains("key Bb-C"))
        XCTAssertTrue(report.contains("NONE"), "flags the song with no lyrics")
        XCTAssertTrue(report.contains("“Sermon”"))
    }

    func testTemplateRuleMatching() {
        let t = ServiceTemplate(name: "x")
        XCTAssertEqual(t.rule(type: "header", title: "COUNTDOWN", header: "")?.result, .presentationNamed("Countdown"))
        XCTAssertEqual(t.rule(type: "header", title: "WORSHIP", header: "")?.result, .header)
        XCTAssertEqual(t.rule(type: "item", title: "Genesis 29", header: "MESSAGE")?.result, .presentationNamed("Sermon"))
        XCTAssertEqual(t.rule(type: "item", title: "Close", header: "CLOSING SONG")?.result, nil)
        XCTAssertEqual(t.rule(type: "song", title: "Anything", header: "MESSAGE")?.result, .songLyrics, "songs always win")
        XCTAssertEqual(t.rule(type: "item", title: "Scripture Reading: John 3:16", header: "WORSHIP")?.result, .scripture)
    }

    func testNullHandling() {
        XCTAssertEqual(PlanningCenterSync.text(NSNull()), "")
        XCTAssertEqual(PlanningCenterSync.text(nil), "")
        XCTAssertEqual(PlanningCenterSync.text(7201044), "7201044")
        XCTAssertEqual(PlanningCenterSync.text("123"), "123")
    }

    func testOldTemplateUpgradesButCustomizedOneIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var seeded = LibraryStore(folder: dir).data
        var legacy = ServiceTemplate(name: "Old"); legacy.rules = ServiceTemplate.legacyDefaultRules; legacy.rulesVersion = nil
        var custom = ServiceTemplate(name: "Mine"); custom.rules = [TemplateRule(match: .song, result: .songLyrics)]; custom.rulesVersion = nil
        seeded.templates = [legacy, custom]
        try JSONEncoder.lumen.encode(seeded).write(to: dir.appendingPathComponent("library.json"))
        let reopened = LibraryStore(folder: dir)
        XCTAssertEqual(reopened.data.templates[0].rules, ServiceTemplate.defaultRules)
        XCTAssertEqual(reopened.data.templates[1].rules.count, 1, "customized rules are never rewritten")
    }
}
