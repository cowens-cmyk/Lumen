import Foundation
import Observation

/// Keeps Lumen's playlists in step with Planning Center service plans.
/// Each plan becomes a playlist; items are mapped through the service template's rules,
/// so songs get CCLI-sourced lyrics from their arrangements, scripture items get Bible slides,
/// and "Sermon"/"Announcements"/"Countdown" items pick up the matching library presentations.
///
/// Safety rules for a live service:
/// - Nothing is synced while something is on screen (a song updating under a live slide could blank it).
/// - Items the operator added by hand are kept, in place, across syncs.
/// - A playlist can be locked and is then never touched.
/// - A failed sync (offline, bad token) changes nothing.
@MainActor
@Observable
final class PlanningCenterSync {
    let store: LibraryStore
    let scripture: ScriptureService

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var log: [String] = []

    /// Tests replace the network with canned Planning Center responses.
    @ObservationIgnored var plansOverride: ((String) async throws -> [PlanningCenterClient.Resource])?
    @ObservationIgnored var itemsOverride: ((String, String) async throws -> PlanningCenterClient.Page)?

    /// Set by the app: true while a slide or media is on the outputs.
    @ObservationIgnored var isLive: () -> Bool = { false }
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
        let t = Timer(timeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isConfigured else { return }
                Task { await self.sync() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func note(_ s: String) {
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Returns false (and does nothing) if a sync is already running or something is live.
    @discardableResult
    func sync() async -> Bool {
        guard !isSyncing else { return false }
        guard isConfigured else { lastError = PlanningCenterClient.PCOError.notConfigured.localizedDescription; return false }
        guard !isLive() else {
            note("Skipped: something is on screen. Clear the outputs and sync again.")
            lastError = "Not syncing while something is on screen."
            return false
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            let s = store.data.settings
            for st in s.pcoServiceTypeIDs {
                let plans = try await fetchPlans(st, days: s.pcoSyncDaysAhead)
                for plan in plans { _ = try await syncPlan(plan, serviceType: st, dryRun: false) }
            }
            lastSync = Date()
            return true
        } catch {
            lastError = error.localizedDescription
            note("Error: \(error.localizedDescription)")
            return false
        }
    }

    /// "What would Lumen do with the next service?" — fetches the next upcoming plan and reports, item by item,
    /// what it found (lyrics? arrangement order? chart?) and which template rule applies. Changes nothing.
    func previewNextPlan() async -> [String] {
        guard isConfigured else { return [PlanningCenterClient.PCOError.notConfigured.localizedDescription] }
        var out: [String] = []
        do {
            for st in store.data.settings.pcoServiceTypeIDs {
                let plans = try await fetchPlans(st, days: 60)
                guard let plan = plans.first else { out.append("Service type \(st): no upcoming plans."); continue }
                out.append("Plan: \(plan.string("dates") ?? plan.id)  (service type \(st))")
                out += try await syncPlan(plan, serviceType: st, dryRun: true)
            }
        } catch { out.append("Error: \(error.localizedDescription)") }
        return out
    }

    private func fetchPlans(_ serviceType: String, days: Int) async throws -> [PlanningCenterClient.Resource] {
        if let plansOverride { return try await plansOverride(serviceType) }
        return try await client.plans(serviceType: serviceType, from: Date(), days: days)
    }

    private var template: ServiceTemplate {
        store.data.templates.first { $0.id == store.data.settings.pcoTemplateID } ?? store.data.templates.first
            ?? ServiceTemplate(name: "Default")
    }

    /// Items the template adds around every service get ids like this, so they're replaced (not duplicated) each sync.
    private static func templateID(_ side: String, _ n: Int) -> String { "template-\(side)-\(n)" }

    private func syncPlan(_ plan: PlanningCenterClient.Resource, serviceType: String, dryRun: Bool) async throws -> [String] {
        var report: [String] = []
        let iso = ISO8601DateFormatter()
        let date = plan.string("sort_date").flatMap { iso.date(from: $0) }
        let page: PlanningCenterClient.Page
        if let itemsOverride { page = try await itemsOverride(serviceType, plan.id) }
        else { page = try await client.items(serviceType: serviceType, plan: plan.id) }
        let included = Dictionary(page.included.map { ("\($0.type):\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        let items = page.data.sorted { ($0.attributes["sequence"] as? Int ?? 0) < ($1.attributes["sequence"] as? Int ?? 0) }

        // ---- Everything that needs the network happens before anything is changed. ----
        let tpl = template
        var scriptureByRef: [String: Presentation] = [:]
        if !dryRun {
            var header = ""
            for item in items {
                let type = item.string("item_type") ?? "item"
                let t = item.string("title") ?? ""
                if type == "header" { header = t }
                guard tpl.rule(type: type, title: t, header: header)?.result == .scripture else { continue }
                for ref in ReferenceParser.parseAll(t + " " + (item.string("description") ?? "")) where scriptureByRef[ref.display] == nil {
                    do { scriptureByRef[ref.display] = try await scripturePresentation(ref) }
                    catch { note("Scripture \(ref.display): \(error.localizedDescription)") }
                }
            }
            // The operator may have gone live while we were waiting on Planning Center. Never change a live service.
            if isLive() { note("Skipped: something went on screen during the sync. Nothing was changed."); return [] }
        }

        // ---- From here on there are no awaits: read the playlist fresh and apply in one step. ----
        var playlist = store.data.playlists.first { $0.pcoPlanID == plan.id }
            ?? Playlist(name: "", pcoPlanID: plan.id, pcoServiceTypeID: serviceType)
        if playlist.syncLocked == true && !dryRun {
            note("Locked, not updated: \(playlist.name)")
            return []
        }
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d"
        let title = [plan.string("title"), plan.string("series_title")].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        playlist.name = [date.map { df.string(from: $0) }, title.isEmpty ? nil : title].compactMap { $0 }.joined(separator: " – ")
        if playlist.name.isEmpty { playlist.name = plan.string("dates") ?? "Service" }
        playlist.date = date

        var newItems: [PlaylistItem] = []
        let oldByPCO = Dictionary(playlist.items.compactMap { i in i.pcoItemID.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        /// Re-use the old row's identity so selection and ordering in the UI don't jump.
        func make(_ kind: PlaylistItemKind, pcoID: String, note: String? = nil) -> PlaylistItem {
            var i = PlaylistItem(kind: kind, pcoItemID: pcoID, note: note)
            if let old = oldByPCO[pcoID] { i.id = old.id; i.color = old.color }
            return i
        }

        for (n, id) in tpl.leadingPresentations.enumerated() {
            newItems.append(make(.presentation(id), pcoID: Self.templateID("lead", n)))
        }

        var currentHeader = ""
        for item in items {
            let type = item.string("item_type") ?? "item"
            let itemTitle = item.string("title") ?? ""
            if type == "header" { currentHeader = itemTitle }
            let noteText = item.string("description").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let rule = tpl.rule(type: type, title: itemTitle, header: currentHeader)
            let result = rule?.result ?? (type == "song" ? .songLyrics : .placeholder)
            var line = "\(type == "song" ? "♪" : type == "header" ? "§" : "•") \(itemTitle.isEmpty ? "(untitled)" : itemTitle)"

            switch result {
            case .skip:
                continue
            case .header:
                newItems.append(make(.header(itemTitle), pcoID: item.id))
                line += "  → section header"
            case .placeholder:
                newItems.append(make(.placeholder(itemTitle), pcoID: item.id, note: noteText))
                line += "  → placeholder (no rule matched; drag a presentation onto it or add a rule)"
            case .presentation(let pid):
                if type == "header" { newItems.append(make(.header(itemTitle), pcoID: item.id)) }
                newItems.append(make(.presentation(pid), pcoID: type == "header" ? item.id + "#slides" : item.id, note: noteText))
                line += "  → library presentation"
            case .presentationNamed(let name):
                let exists = store.data.presentations.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                let p = presentationNamed(name, dryRun: dryRun)
                // A header that maps to a presentation (COUNTDOWN) keeps its header row too.
                if type == "header" { newItems.append(make(.header(itemTitle), pcoID: item.id)) }
                newItems.append(make(.presentation(p.id), pcoID: type == "header" ? item.id + "#slides" : item.id, note: noteText))
                line += "  → “\(name)”" + (exists ? "" : " (will be created empty; add its video or slides)")
            case .songLyrics:
                let info = songInfo(item: item, included: included)
                line += "  key \(item.string("key_name") ?? "?")  \(info)"
                if let p = songPresentation(item: item, included: included, dryRun: dryRun) {
                    newItems.append(make(.presentation(p.id), pcoID: item.id, note: noteText))
                } else {
                    newItems.append(make(.placeholder("\(itemTitle) — no lyrics in Planning Center"), pcoID: item.id, note: noteText))
                }
            case .scripture:
                let refs = ReferenceParser.parseAll(itemTitle + " " + (item.string("description") ?? ""))
                line += refs.isEmpty ? "  → no Bible reference found" : "  → " + refs.map(\.display).joined(separator: ", ")
                if refs.isEmpty { newItems.append(make(.placeholder(itemTitle), pcoID: item.id, note: noteText)) }
                for (k, ref) in refs.enumerated() {
                    let pid = k == 0 ? item.id : "\(item.id)#\(k)"
                    if let p = scriptureByRef[ref.display] { newItems.append(make(.presentation(p.id), pcoID: pid)) }
                    else { newItems.append(make(.placeholder(ref.display), pcoID: pid)) }
                }
            }
            report.append(line)
        }

        for (n, id) in tpl.trailingPresentations.enumerated() {
            newItems.append(make(.presentation(id), pcoID: Self.templateID("trail", n)))
        }

        if dryRun { return report }

        newItems = Self.keepingManualItems(from: playlist.items, in: newItems)
        if newItems != playlist.items || playlist.pcoUpdatedAt != plan.string("updated_at") {
            playlist.items = newItems
            playlist.pcoUpdatedAt = plan.string("updated_at")
            store.upsert(playlist)
            note("Updated \(playlist.name) (\(newItems.count) items)")
        }
        return report
    }

    /// Rows the operator added by hand (no Planning Center id) stay where they were: right after the
    /// Planning Center row that preceded them. If that row is gone they go to the end.
    static func keepingManualItems(from old: [PlaylistItem], in new: [PlaylistItem]) -> [PlaylistItem] {
        var result = new
        var anchor: String? = nil
        for item in old {
            if let pid = item.pcoItemID { anchor = pid; continue }
            var at = 0
            if let anchor {
                if let i = result.lastIndex(where: { $0.pcoItemID == anchor }) { at = i + 1 } else { at = result.count }
                // keep consecutive manual rows in order
                while at < result.count, result[at].pcoItemID == nil, old.contains(where: { $0.id == result[at].id }) { at += 1 }
            }
            result.insert(item, at: min(at, result.count))
        }
        return result
    }

    private func presentationNamed(_ name: String, dryRun: Bool) -> Presentation {
        if let p = store.data.presentations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        let lower = name.lowercased()
        let kind: PresentationKind = lower.contains("sermon") ? .sermon : lower.contains("announce") ? .announcement
            : lower.contains("countdown") ? .media : .generic
        let p = Presentation(name: name, kind: kind)
        if !dryRun { store.upsert(p) }
        return p
    }

    private func scripturePresentation(_ ref: BibleReference) async throws -> Presentation {
        var p = try await scripture.presentation(for: ref)
        if let existing = store.data.presentations.first(where: { $0.kind == .scripture && $0.name == p.name }) { return existing }
        p.notes = "Created from Planning Center"
        store.upsert(p)
        return p
    }

    /// Planning Center sends JSON null for blank fields; Foundation turns that into NSNull, which must not become "<null>".
    static func text(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let n as Int: return String(n)
        case let n as NSNumber where !(any is NSNull): return n.stringValue
        default: return ""
        }
    }

    private func songInfo(item: PlanningCenterClient.Resource, included: [String: PlanningCenterClient.Resource]) -> String {
        let arr = item.relID("arrangement").flatMap { included["Arrangement:\($0)"] }
        let lyrics = arr?.string("lyrics") ?? ""
        let seq = (item.attributes["custom_arrangement_sequence"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
            ?? (arr?.attributes["sequence"] as? [String]) ?? []
        return "lyrics: " + (lyrics.isEmpty ? "NONE (import lyrics in Planning Center or Lumen)" : "\(lyrics.count) chars")
            + " · order: " + (seq.isEmpty ? "default" : seq.joined(separator: " "))
            + " · chart: " + ((arr?.string("chord_chart")?.isEmpty == false) ? "yes (key \(arr?.string("chord_chart_key") ?? "?"))" : "none")
    }

    private func songPresentation(item: PlanningCenterClient.Resource,
                                  included: [String: PlanningCenterClient.Resource], dryRun: Bool) -> Presentation? {
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
            // Chords only: the order comes from Planning Center, and a synced song must stay in sync.
            if !hasChords { ChordMatcher.apply(chart, to: &p, maxLines: maxLines, applyOrder: false) }
        }

        if var existing = store.data.presentations.first(where: { $0.pcoArrangementID == arrID && arrID != nil }) {
            if !existing.lockedFromSync, existing.pcoUpdatedAt != updated, !dryRun {
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
        p.ccli = Self.text(song?.attributes["ccli_number"])
        p.pcoSongID = songID
        p.pcoArrangementID = arrID
        p.pcoUpdatedAt = updated
        applyChords(&p)
        if let arrName = arr?.string("name"), arrName.lowercased() != "default arrangement" { p.name += " (\(arrName))" }
        if !dryRun { store.upsert(p); note("Added song: \(p.name)") }
        return p
    }
}
