import Foundation

enum BibleProviderKind: String, Codable, CaseIterable, Identifiable {
    case bibleAPIcom, apiBible, esv, local
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bibleAPIcom: "bible-api.com (public domain, no key)"
        case .apiBible: "API.Bible (2,500+ translations, free key)"
        case .esv: "ESV API (Crossway key)"
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

    // Themes per presentation kind
    var defaultThemeByKind: [PresentationKind: UUID] = [:]
    var defaultLookID: UUID? = nil
    var transitionSeconds: Double = 0.35

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
}
