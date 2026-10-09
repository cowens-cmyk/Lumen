import Foundation
import Observation

/// Counts what couldn't be read while loading, so the operator is told and the original file is kept.
final class DecodeLoss {
    var dropped: [String] = []
}

extension CodingUserInfoKey {
    static let decodeLoss = CodingUserInfoKey(rawValue: "lumen.decodeLoss")!
}

/// Decodes to nil instead of throwing, so one unreadable element in a list can't sink the whole library.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
}

struct LibraryData: Codable {
    var version = 1
    var presentations: [Presentation] = []
    var playlists: [Playlist] = []
    var themes: [Theme] = []
    var looks: [Look] = []
    var screens: [Screen] = []
    var props: [Prop] = []
    var macros: [Macro] = []
    var timers: [ServiceTimer] = []
    var stageLayouts: [StageLayout] = []
    var templates: [ServiceTemplate] = []
    var schedules: [ScheduledTrigger] = []
    var midiMappings: [MIDIMapping] = []
    var settings = AppSettings()

    enum CodingKeys: String, CodingKey {
        case version, presentations, playlists, themes, looks, screens, props, macros, timers
        case stageLayouts, templates, schedules, midiMappings, settings
    }

    init() {}

    /// Tolerant on purpose. A list element that can't be read (written by a newer version, or damaged) is skipped
    /// and reported; it never discards the rest of the library. Unreadable settings fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let loss = decoder.userInfo[.decodeLoss] as? DecodeLoss
        func list<T: Decodable>(_ key: CodingKeys, _ what: String) -> [T] {
            guard let raw = try? c.decode([Lossy<T>].self, forKey: key) else {
                if c.contains(key) { loss?.dropped.append("all \(what)") }
                return []
            }
            let good = raw.compactMap(\.value)
            if good.count != raw.count { loss?.dropped.append("\(raw.count - good.count) of \(raw.count) \(what)") }
            return good
        }
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        presentations = list(.presentations, "songs/presentations")
        playlists = list(.playlists, "playlists")
        themes = list(.themes, "themes")
        looks = list(.looks, "looks")
        screens = list(.screens, "screens")
        props = list(.props, "props")
        macros = list(.macros, "macros")
        timers = list(.timers, "timers")
        stageLayouts = list(.stageLayouts, "stage layouts")
        templates = list(.templates, "service templates")
        schedules = list(.schedules, "scheduled triggers")
        midiMappings = list(.midiMappings, "MIDI mappings")
        settings = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
    }
}

/// Owns the persistent library and saves it to Application Support.
@MainActor
@Observable
final class LibraryStore {
    var data: LibraryData {
        didSet { scheduleSave() }
    }

    /// Set when the library file was unreadable and an automatic backup was used instead.
    @ObservationIgnored private(set) var restoredFromBackup: String?
    /// Set when some of the library couldn't be read and was skipped (shown to the operator at launch).
    @ObservationIgnored private(set) var loadNotice: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored let folder: URL

    nonisolated static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lumen", isDirectory: true)
    }

    var mediaFolder: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    var biblesFolder: URL { folder.appendingPathComponent("Bibles", isDirectory: true) }
    private var fileURL: URL { folder.appendingPathComponent("library.json") }

    init(folder: URL = LibraryStore.defaultFolder) {
        self.folder = folder
        let fm = FileManager.default
        for dir in [folder, folder.appendingPathComponent("Media"), folder.appendingPathComponent("Bibles")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let file = folder.appendingPathComponent("library.json")
        let loss = DecodeLoss()
        let decoder = JSONDecoder.lumen
        decoder.userInfo[.decodeLoss] = loss
        if let raw = try? Data(contentsOf: file),
           let decoded = try? decoder.decode(LibraryData.self, from: raw) {
            data = decoded
            if !loss.dropped.isEmpty {
                // Keep exactly what was on disk before the next save overwrites it, and say what was skipped.
                try? raw.write(to: folder.appendingPathComponent("library-before-skipping-\(Int(Date().timeIntervalSince1970)).json"))
                loadNotice = "Couldn't read " + loss.dropped.joined(separator: ", ") + ". They were skipped; the original file is kept in Lumen's library folder."
            }
        } else {
            if fm.fileExists(atPath: file.path) {
                // Never silently clobber a library we failed to read: keep the damaged file for inspection…
                let backup = folder.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.copyItem(at: file, to: backup)
            }
            // …and come back up on the newest backup that does read, rather than an empty library.
            if let (restored, name) = Self.newestReadableBackup(in: folder) {
                data = restored
                restoredFromBackup = name
            } else {
                data = SeedData.make()
            }
        }
        backUpDaily()
        backUpIfVersionChanged()
        ensureDefaults()
        if !fm.fileExists(atPath: file.path) { saveNow() }
    }

    /// The newest file in Backups/ that decodes as a library (daily and version-change copies both live there).
    static func newestReadableBackup(in folder: URL) -> (LibraryData, String)? {
        let dir = folder.appendingPathComponent("Backups", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for f in files {
            if let raw = try? Data(contentsOf: f), let lib = try? JSONDecoder.lumen.decode(LibraryData.self, from: raw) { return (lib, f.lastPathComponent) }
        }
        return nil
    }

    /// Keeps the `keep` newest files with this prefix, judged by modification date (file names like 1.9 and 1.10 don't sort).
    static func prune(_ dir: URL, prefix: String, keep: Int) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        files.dropFirst(keep).forEach { try? fm.removeItem(at: $0.0) }
    }

    /// One copy of the library per day (the newest 14 are kept), so a bad day costs at most a day of edits.
    private func backUpDaily() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let backups = folder.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let dest = backups.appendingPathComponent("daily-\(day).json")
        if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: fileURL, to: dest) }
        Self.prune(backups, prefix: "daily-", keep: 14)
    }

    /// Auto-updates must never cost anyone their songs: the first time a new version opens the library,
    /// keep a copy of exactly what the previous version saved (the newest 10 are kept).
    private func backUpIfVersionChanged() {
        let fm = FileManager.default
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let backups = folder.appendingPathComponent("Backups", isDirectory: true)
        let marker = backups.appendingPathComponent(".last-version")
        let last = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard last != current, fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: fileURL, to: backups.appendingPathComponent("library-\(last ?? "unknown")-before-\(current)-\(stamp).json"))
        try? current.write(to: marker, atomically: true, encoding: .utf8)
        Self.prune(backups, prefix: "library-", keep: 10)
    }

    /// Fills in anything a fresh or older library is missing.
    private func ensureDefaults() {
        // Templates still on the original built-in rules get the improved ones (COUNTDOWN, anything under MESSAGE…).
        for i in data.templates.indices where (data.templates[i].rulesVersion ?? 1) < 2 {
            if data.templates[i].rules == ServiceTemplate.legacyDefaultRules { data.templates[i].rules = ServiceTemplate.defaultRules }
            data.templates[i].rulesVersion = 2
        }
        if data.themes.isEmpty || data.screens.isEmpty || data.looks.isEmpty {
            let seed = SeedData.make()
            if data.themes.isEmpty { data.themes = seed.themes }
            if data.screens.isEmpty { data.screens = seed.screens }
            if data.looks.isEmpty { data.looks = seed.looks }
            if data.stageLayouts.isEmpty { data.stageLayouts = seed.stageLayouts }
            if data.templates.isEmpty { data.templates = seed.templates }
            data.settings.defaultThemeByKind.merge(seed.settings.defaultThemeByKind) { a, _ in a }
            if data.settings.defaultLookID == nil { data.settings.defaultLookID = seed.settings.defaultLookID }
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            let raw = try JSONEncoder.lumen.encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Lumen: failed to save library: \(error)")
        }
    }

    /// Edits one slide in place (used for quick changes from the slide grid).
    func updateSlide(in presentationID: UUID, slideID: UUID, _ edit: (inout Slide) -> Void) {
        guard let pi = data.presentations.firstIndex(where: { $0.id == presentationID }) else { return }
        for gi in data.presentations[pi].groups.indices {
            if let si = data.presentations[pi].groups[gi].slides.firstIndex(where: { $0.id == slideID }) {
                edit(&data.presentations[pi].groups[gi].slides[si])
                data.presentations[pi].updatedAt = Date()
                return
            }
        }
    }

    // MARK: Lookups

    var defaultMediaScale: ScaleMode { data.settings.defaultMediaScale ?? .fit }

    func presentation(_ id: UUID?) -> Presentation? {
        guard let id else { return nil }
        return data.presentations.first { $0.id == id }
    }

    func theme(_ id: UUID?) -> Theme? {
        guard let id else { return nil }
        return data.themes.first { $0.id == id }
    }

    func look(_ id: UUID?) -> Look? {
        guard let id else { return nil }
        return data.looks.first { $0.id == id }
    }

    func prop(_ id: UUID) -> Prop? { data.props.first { $0.id == id } }
    func macro(_ id: UUID) -> Macro? { data.macros.first { $0.id == id } }
    func timer(_ id: UUID) -> ServiceTimer? { data.timers.first { $0.id == id } }

    /// Resolves which theme a presentation uses (explicit → default for its kind → first theme).
    func resolvedTheme(for presentation: Presentation?, slide: Slide? = nil) -> Theme {
        if let t = theme(slide?.themeOverride) { return t }
        if let t = theme(presentation?.themeID) { return t }
        if let kind = presentation?.kind, let t = theme(data.settings.defaultThemeByKind[kind]) { return t }
        return data.themes.first ?? Theme(name: "Default")
    }

    func upsert(_ p: Presentation) {
        var p = p
        p.updatedAt = Date()
        if let i = data.presentations.firstIndex(where: { $0.id == p.id }) {
            data.presentations[i] = p
        } else {
            data.presentations.append(p)
        }
    }

    func upsert(_ pl: Playlist) {
        if let i = data.playlists.firstIndex(where: { $0.id == pl.id }) {
            data.playlists[i] = pl
        } else {
            data.playlists.append(pl)
        }
    }

    /// Copies an imported file into the library's media folder so the library stays self-contained.
    func importMedia(_ url: URL) -> URL {
        let dest = mediaFolder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return url
        }
    }
}

extension JSONEncoder {
    static var lumen: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var lumen: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
