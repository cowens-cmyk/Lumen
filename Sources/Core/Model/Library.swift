import Foundation
import Observation

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
}

/// Owns the persistent library and saves it to Application Support.
@MainActor
@Observable
final class LibraryStore {
    var data: LibraryData {
        didSet { scheduleSave() }
    }

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
        if let raw = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder.lumen.decode(LibraryData.self, from: raw) {
            data = decoded
        } else {
            if fm.fileExists(atPath: file.path) {
                // Never silently clobber a library we failed to read.
                let backup = folder.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.copyItem(at: file, to: backup)
            }
            data = SeedData.make()
        }
        backUpIfVersionChanged()
        ensureDefaults()
        if !fm.fileExists(atPath: file.path) { saveNow() }
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
        let old = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("library-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        old.dropFirst(10).forEach { try? fm.removeItem(at: $0) }
    }

    /// Fills in anything a fresh or older library is missing.
    private func ensureDefaults() {
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
