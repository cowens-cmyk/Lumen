import Foundation

enum BibleProviderKind: String, Codable, CaseIterable, Identifiable {
    case bibleAPIcom, apiBible, esv, nlt, local
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bibleAPIcom: "bible-api.com (public domain, no key)"
        case .apiBible: "API.Bible (2,500+ translations, free key)"
        case .esv: "ESV API (Crossway key)"
        case .nlt: "NLT API (Tyndale key)"
        case .local: "Imported Bible files (XML)"
        }
    }
}

struct AppSettings: Codable, Hashable {
    // Planning Center
    var pcoAppID: String = ""
    var pcoServiceTypeIDs: [String] = []
    var pcoSyncDaysAhead: Int = 35
    var pcoAutoSyncMinutes: Int = 10
    var pcoTemplateID: UUID? = nil

    // Bible
    var bibleProvider: BibleProviderKind = .bibleAPIcom
    var bibleTranslation: String = "kjv"
    var bibleVersesPerSlide: Int = 1
    var bibleMaxCharsPerSlide: Int = 260
    /// The chosen Bible: "v:esv" (one of the church's curated versions) or "p:<provider>:<id>" (anything else).
    /// Nil falls back to the older provider + translation pair.
    var bibleSelection: String? = nil
    /// Scripture is shown as straight running text. Tick this to keep the line breaks the translation has (poetry, etc.).
    var bibleKeepLineBreaks: Bool? = nil

    // Themes per presentation kind
    var defaultThemeByKind: [PresentationKind: UUID] = [:]
    var defaultLookID: UUID? = nil
    var transitionSeconds: Double = 0.35
    /// How images/videos that aren't screen-shaped are placed. Nil = fit (scaled to the edges, black elsewhere).
    var defaultMediaScale: ScaleMode? = nil

    // Remote control
    var remoteEnabled = true
    var remotePort: Int = 8090
    var remotePIN: String = ""

    // Volunteer mode
    var volunteerPIN: String = "1234"
    var startInVolunteerMode = false

    // MIDI
    var midiEnabled = true
    var midiOutputName = "Lumen"

    // AI listening
    var listenInputDeviceUID: String = ""
    var lyricFollowAutoAdvance = true
    var lyricFollowThreshold: Double = 0.62
    var scriptureDetection = true
    var speechLocale = "en-US"

    // Calendar
    var calendarTriggersEnabled = false
    var calendarName: String = ""

    enum CodingKeys: String, CodingKey {
        case pcoAppID, pcoServiceTypeIDs, pcoSyncDaysAhead, pcoAutoSyncMinutes, pcoTemplateID, bibleProvider, bibleTranslation, bibleVersesPerSlide, bibleMaxCharsPerSlide, bibleSelection, bibleKeepLineBreaks, defaultThemeByKind, defaultLookID, transitionSeconds, defaultMediaScale, remoteEnabled, remotePort, remotePIN, volunteerPIN, startInVolunteerMode, midiEnabled, midiOutputName, listenInputDeviceUID, lyricFollowAutoAdvance, lyricFollowThreshold, scriptureDetection, speechLocale, calendarTriggersEnabled, calendarName
    }

    /// A missing or unreadable setting falls back to its default, so adding a setting in a new version never
    /// makes an older settings file unreadable (and never costs anyone their library).
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ path: WritableKeyPath<AppSettings, T>) {
            if let v = try? c.decode(T.self, forKey: key) { self[keyPath: path] = v }
        }
        read(.pcoAppID, \.pcoAppID)
        read(.pcoServiceTypeIDs, \.pcoServiceTypeIDs)
        read(.pcoSyncDaysAhead, \.pcoSyncDaysAhead)
        read(.pcoAutoSyncMinutes, \.pcoAutoSyncMinutes)
        read(.pcoTemplateID, \.pcoTemplateID)
        read(.bibleProvider, \.bibleProvider)
        read(.bibleTranslation, \.bibleTranslation)
        read(.bibleVersesPerSlide, \.bibleVersesPerSlide)
        read(.bibleMaxCharsPerSlide, \.bibleMaxCharsPerSlide)
        read(.bibleSelection, \.bibleSelection)
        read(.bibleKeepLineBreaks, \.bibleKeepLineBreaks)
        read(.defaultThemeByKind, \.defaultThemeByKind)
        read(.defaultLookID, \.defaultLookID)
        read(.transitionSeconds, \.transitionSeconds)
        read(.defaultMediaScale, \.defaultMediaScale)
        read(.remoteEnabled, \.remoteEnabled)
        read(.remotePort, \.remotePort)
        read(.remotePIN, \.remotePIN)
        read(.volunteerPIN, \.volunteerPIN)
        read(.startInVolunteerMode, \.startInVolunteerMode)
        read(.midiEnabled, \.midiEnabled)
        read(.midiOutputName, \.midiOutputName)
        read(.listenInputDeviceUID, \.listenInputDeviceUID)
        read(.lyricFollowAutoAdvance, \.lyricFollowAutoAdvance)
        read(.lyricFollowThreshold, \.lyricFollowThreshold)
        read(.scriptureDetection, \.scriptureDetection)
        read(.speechLocale, \.speechLocale)
        read(.calendarTriggersEnabled, \.calendarTriggersEnabled)
        read(.calendarName, \.calendarName)
    }

    init() {}

}
