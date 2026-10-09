import Foundation
import Observation

/// Keeps Lumen's playlists in step with Planning Center service plans.
/// Each plan becomes a playlist; items are mapped through the service template's rules,
/// so songs get CCLI-sourced lyrics from their arrangements, scripture items get Bible slides,
/// and "Sermon"/"Announcements" items pick up the matching library presentations.
@MainActor
@Observable
final class PlanningCenterSync {
    let store: LibraryStore
    let scripture: ScriptureService

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var log: [String] = []

    @ObservationIgnored private var timer: Timer?

    init(store: LibraryStore, scripture: ScriptureService) {
        self.store = store
        self.scripture = scripture
    }

    var client: PlanningCenterClient {
        PlanningCenterClient(appID: store.data.settings.pcoAppID, secret: Keychain.get("pco-secret"))
    }

    var isConfigured: Bool { !store.data.settings.pcoAppID.isEmpty && !store.data.settings.pcoServiceTypeIDs.isEmpty }

    func startAutoSync() {
        timer?.invalidate()
        let minutes = store.data.settings.pcoAutoSyncMinutes
        guard minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isConfigured else { return }
                Task { await self.sync() }
            }
        }
    }

    private func note(_ s: String) {
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func sync() async {
        guard !isSyncing else { return }
        guard isConfigured else { lastError = PlanningCenterClient.PCOError.notConfigured.localizedDescription; return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            let s = store.data.settings
            for st in s.pcoServiceTypeIDs {
                let plans = try await client.plans(serviceType: st, from: Date(), days: s.pcoSyncDaysAhead)
                for plan in plans {
                    try await syncPlan(plan, serviceType: st)
                }
            }
            lastSync = Date()
        } catch {
            lastError = error.localizedDescription
            note("Error: \(error.localizedDescription)")
        }
    }

    private var template: ServiceTemplate {
        store.data.templates.first { $0.id == store.data.settings.pcoTemplateID } ?? store.data.templates.first
            ?? ServiceTemplate(name: "Default")
    }

    private func syncPlan(_ plan: PlanningCenterClient.Resource, serviceType: String) async throws {
        let iso = ISO8601DateFormatter()
        let date = plan.string("sort_date").flatMap { iso.date(from: $0) }
        var playlist = store.data.playlists.first { $0.pcoPlanID == plan.id }
            ?? Playlist(name: "", pcoPlanID: plan.id, pcoServiceTypeID: serviceType)
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d"
        let title = [plan.string("title"), plan.string("series_title")].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        playlist.name = [date.map { df.string(from: $0) }, title.isEmpty ? nil : title].compactMap { $0 }.joined(separator: " – ")
        if playlist.name.isEmpty { playlist.name = plan.string("dates") ?? "Service" }
        playlist.date = date

        let page = try await client.items(serviceType: serviceType, plan: plan.id)
        let included = Dictionary(page.included.map { ("\($0.type):\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        let items = page.data.sorted { ($0.attributes["sequence"] as? Int ?? 0) < ($1.attributes["sequence"] as? Int ?? 0) }

        var newItems: [PlaylistItem] = []
        let tpl = template
        let existingByPCO = Dictionary(playlist.items.compactMap { i in i.pcoItemID.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        func keepID(_ item: PlaylistItem) -> PlaylistItem {
            var i = item
            if let pid = i.pcoItemID, let old = existingByPCO[pid] { i.id = old.id }
            return i
        }

        for id in tpl.leadingPresentations { newItems.append(PlaylistItem(kind: .presentation(id))) }

        for item in items {
            let type = item.string("item_type") ?? "item"
            let itemTitle = item.string("title") ?? ""
            let rule = tpl.rules.first { r in
                switch r.match {
                case .song: type == "song"
                case .header: type == "header"
                case .media: type == "media"
                case .titleContains: type != "song" && type != "header" && !r.text.isEmpty
                    && itemTitle.lowercased().contains(r.text.lowercased())
                }
            }
            let result = rule?.result ?? (type == "song" ? .songLyrics : .placeholder)
            switch result {
            case .skip:
                continue
            case .header:
                newItems.append(keepID(PlaylistItem(kind: .header(itemTitle), pcoItemID: item.id)))
            case .placeholder:
                newItems.append(keepID(PlaylistItem(kind: .placeholder(itemTitle), pcoItemID: item.id)))
            case .presentation(let pid):
                newItems.append(keepID(PlaylistItem(kind: .presentation(pid), pcoItemID: item.id)))
            case .presentationNamed(let name):
                let p = presentationNamed(name, itemTitle: itemTitle)
                newItems.append(keepID(PlaylistItem(kind: .presentation(p.id), pcoItemID: item.id)))
            case .songLyrics:
                if let p = songPresentation(item: item, included: included) {
                    newItems.append(keepID(PlaylistItem(kind: .presentation(p.id), pcoItemID: item.id)))
                } else {
                    newItems.append(keepID(PlaylistItem(kind: .placeholder("\(itemTitle) (no lyrics in Planning Center)"), pcoItemID: item.id)))
                }
            case .scripture:
                let text = itemTitle + " " + (item.string("description") ?? "")
                let refs = ReferenceParser.parseAll(text)
                if refs.isEmpty {
                    newItems.append(keepID(PlaylistItem(kind: .placeholder(itemTitle), pcoItemID: item.id)))
                }
                for ref in refs {
                    do {
                        let p = try await scripturePresentation(ref)
                        newItems.append(keepID(PlaylistItem(kind: .presentation(p.id), pcoItemID: item.id)))
                    } catch {
                        note("Scripture \(ref.display): \(error.localizedDescription)")
                        newItems.append(keepID(PlaylistItem(kind: .placeholder(ref.display), pcoItemID: item.id)))
                    }
                }
            }
        }

        for id in tpl.trailingPresentations { newItems.append(PlaylistItem(kind: .presentation(id))) }

        if newItems != playlist.items || playlist.pcoUpdatedAt != plan.string("updated_at") {
            playlist.items = newItems
            playlist.pcoUpdatedAt = plan.string("updated_at")
            store.upsert(playlist)
            note("Updated \(playlist.name) (\(newItems.count) items)")
        }
    }

    private func presentationNamed(_ name: String, itemTitle: String) -> Presentation {
        if let p = store.data.presentations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        let kind: PresentationKind = name.lowercased().contains("sermon") ? .sermon
            : name.lowercased().contains("announce") ? .announcement : .generic
        let p = Presentation(name: name, kind: kind)
        store.upsert(p)
        return p
    }

    private func scripturePresentation(_ ref: BibleReference) async throws -> Presentation {
        var p = try await scripture.presentation(for: ref)
        if let existing = store.data.presentations.first(where: { $0.kind == .scripture && $0.name == p.name }) {
            return existing
        }
        p.notes = "Created from Planning Center"
        store.upsert(p)
        return p
    }

    private func songPresentation(item: PlanningCenterClient.Resource,
                                  included: [String: PlanningCenterClient.Resource]) -> Presentation? {
        let songID = item.relID("song")
        let arrID = item.relID("arrangement")
        let song = songID.flatMap { included["Song:\($0)"] }
        let arr = arrID.flatMap { included["Arrangement:\($0)"] }
        guard let lyrics = arr?.string("lyrics"), !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Fall back to a song already in the library (e.g. imported from SongSelect by hand).
            if let songID, let p = store.data.presentations.first(where: { $0.pcoSongID == songID }) { return p }
            return nil
        }
        // A plan item can override the arrangement's sequence.
        let itemSeq = item.attributes["custom_arrangement_sequence"] as? [String]
        let sequence = (itemSeq?.isEmpty == false ? itemSeq : nil) ?? (arr?.attributes["sequence"] as? [String]) ?? []
        let updated = arr?.string("updated_at")
        let name = song?.string("title") ?? item.string("title") ?? "Song"
        let maxLines = store.resolvedTheme(for: Presentation(name: "", kind: .song)).maxLinesPerSlide

        // Planning Center arrangements can carry a chord chart (ChordPro or chords-over-lyrics).
        func applyChords(_ p: inout Presentation) {
            guard let chartText = arr?.string("chord_chart"), !chartText.isEmpty,
                  var chart = try? ChordChartReader.read(text: chartText, fallbackTitle: p.name) else { return }
            if let k = arr?.string("chord_chart_key"), !k.isEmpty { chart.key = k }
            // Keep hand-fixed chords unless the slides had none.
            let hasChords = p.groups.contains { $0.slides.contains { !($0.chords ?? []).isEmpty } }
            if !hasChords { ChordMatcher.apply(chart, to: &p, maxLines: maxLines) }
        }

        if var existing = store.data.presentations.first(where: { $0.pcoArrangementID == arrID && arrID != nil }) {
            if !existing.lockedFromSync, existing.pcoUpdatedAt != updated {
                LyricParser.apply(text: lyrics, to: &existing, maxLines: maxLines, sequence: sequence)
                applyChords(&existing)
                existing.pcoUpdatedAt = updated
                store.upsert(existing)
                note("Updated lyrics: \(existing.name)")
            }
            return existing
        }
        var p = LyricParser.presentation(name: name, kind: .song, text: lyrics, maxLines: maxLines, sequence: sequence)
        p.author = song?.string("author") ?? ""
        p.copyright = song?.string("copyright") ?? ""
        p.ccli = (song?.attributes["ccli_number"]).map { "\($0)" } ?? ""
        p.pcoSongID = songID
        p.pcoArrangementID = arrID
        p.pcoUpdatedAt = updated
        applyChords(&p)
        if let arrName = arr?.string("name"), arrName.lowercased() != "default arrangement" { p.name += " (\(arrName))" }
        store.upsert(p)
        note("Added song: \(p.name)")
        return p
    }
}
