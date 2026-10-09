import Foundation
import SwiftUI

// MARK: - Basics

struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = ns.redComponent; g = ns.greenComponent; b = ns.blueComponent; a = ns.alphaComponent
    }

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
        a = 1
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }

    func with(alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}

enum PresentationKind: String, Codable, CaseIterable, Identifiable {
    case song, scripture, sermon, announcement, media, generic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .song: "Song"
        case .scripture: "Scripture"
        case .sermon: "Sermon"
        case .announcement: "Announcement"
        case .media: "Media"
        case .generic: "Other"
        }
    }
    var symbol: String {
        switch self {
        case .song: "music.note"
        case .scripture: "book.closed"
        case .sermon: "text.bubble"
        case .announcement: "megaphone"
        case .media: "photo.on.rectangle"
        case .generic: "rectangle.on.rectangle"
        }
    }
}

// MARK: - Media

enum MediaKind: String, Codable, CaseIterable {
    case image, video, audio, web, capture, ndi, color
}

enum ScaleMode: String, Codable, CaseIterable {
    case fill, fit, stretch
}

struct MediaRef: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: MediaKind
    /// File path, URL string, capture device unique ID, or NDI source name depending on `kind`.
    var location: String
    var name: String = ""
    var loop: Bool = true
    var muted: Bool = false
    var volume: Double = 1
    var scale: ScaleMode = .fill
    var color: RGBA? = nil

    var url: URL? {
        switch kind {
        case .image, .video, .audio: URL(fileURLWithPath: location)
        case .web: URL(string: location)
        default: nil
        }
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if let url, url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        return location
    }
}

// MARK: - Slides & presentations

struct Slide: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String = ""
    /// Shown as the reference / footer line (e.g. "John 3:16 ESV").
    var label: String = ""
    var notes: String = ""
    var media: MediaRef? = nil
    var actions: [SlideAction] = []
    var enabled: Bool = true
    var themeOverride: UUID? = nil
    /// Chords placed over this slide's lyrics, stored as letter names (Nashville numbers are derived from the song key).
    /// Optional so libraries saved before chord support still decode.
    var chords: [ChordPlacement]? = nil
}

/// One chord sitting over a character of a slide line.
struct ChordPlacement: Codable, Hashable {
    /// Line within the slide text (0-based, split on "\n").
    var line: Int
    /// Character offset within that line where the chord lands.
    var index: Int
    /// Letter-name chord as written on the chart, e.g. "D/F#", "Em7", "Csus2".
    var chord: String
}

struct SlideGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: RGBA
    var slides: [Slide]

    static func color(for name: String) -> RGBA {
        let n = name.lowercased()
        if n.hasPrefix("verse") { return RGBA(hex: "#3B82F6") }
        if n.hasPrefix("pre") { return RGBA(hex: "#A855F7") }
        if n.hasPrefix("chorus") || n.hasPrefix("refrain") { return RGBA(hex: "#EF4444") }
        if n.hasPrefix("bridge") { return RGBA(hex: "#22C55E") }
        if n.hasPrefix("tag") || n.hasPrefix("ending") || n.hasPrefix("outro") { return RGBA(hex: "#F59E0B") }
        if n.hasPrefix("intro") || n.hasPrefix("instrumental") || n.hasPrefix("interlude") { return RGBA(hex: "#64748B") }
        return RGBA(hex: "#0EA5E9")
    }
}

struct SlideshowSettings: Codable, Hashable {
    var enabled = false
    var interval: Double = 8
    var loop = true
}

struct Presentation: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: PresentationKind = .generic
    var groups: [SlideGroup] = []
    /// Ordered group IDs. Groups may repeat (Chorus twice). Empty means "groups in order".
    var arrangement: [UUID] = []
    var themeID: UUID? = nil
    var author: String = ""
    var copyright: String = ""
    var ccli: String = ""
    var notes: String = ""
    var slideshow = SlideshowSettings()
    var pcoSongID: String? = nil
    var pcoArrangementID: String? = nil
    var pcoUpdatedAt: String? = nil
    /// Image or looping video behind this presentation's words (overrides the theme's background).
    var background: MediaRef? = nil
    /// When true, Planning Center sync never overwrites local lyric edits.
    var lockedFromSync = false
    /// Song key for Nashville numbers, e.g. "G", "Bb", "Em". Nil = unknown (stage shows letters).
    var key: String? = nil
    var updatedAt = Date()

    /// The slides in arrangement order (one entry per time it's shown).
    var orderedSlides: [SlideRef] {
        let order = arrangement.isEmpty ? groups.map(\.id) : arrangement
        var out: [SlideRef] = []
        for gid in order {
            guard let g = groups.first(where: { $0.id == gid }) else { continue }
            for (i, s) in g.slides.enumerated() where s.enabled {
                out.append(SlideRef(groupID: g.id, groupName: g.name, groupColor: g.color,
                                    slide: s, indexInGroup: i, groupCount: g.slides.count))
            }
        }
        return out
    }
}

struct SlideRef: Identifiable, Hashable {
    var groupID: UUID
    var groupName: String
    var groupColor: RGBA
    var slide: Slide
    var indexInGroup: Int
    var groupCount: Int
    var id: UUID { slide.id }
}

// MARK: - Actions & macros

enum ClearTarget: String, Codable, CaseIterable {
    case all, slide, media, props, messages, audio
    var title: String {
        switch self {
        case .all: "Clear All"
        case .slide: "Clear Slide"
        case .media: "Clear Media"
        case .props: "Clear Props"
        case .messages: "Clear Messages"
        case .audio: "Clear Audio"
        }
    }
}

struct MIDIMessage: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable { case noteOn, noteOff, controlChange, programChange }
    var kind: Kind = .noteOn
    var channel: Int = 1      // 1...16
    var number: Int = 60      // note / cc / program
    var value: Int = 127      // velocity / cc value

    var summary: String {
        switch kind {
        case .noteOn: "Note On ch\(channel) #\(number) v\(value)"
        case .noteOff: "Note Off ch\(channel) #\(number)"
        case .controlChange: "CC ch\(channel) #\(number) = \(value)"
        case .programChange: "Program ch\(channel) #\(number)"
        }
    }
}

enum SlideAction: Codable, Hashable {
    case triggerMacro(UUID)
    case setLook(UUID)
    case showProp(UUID)
    case hideProp(UUID)
    case startTimer(UUID)
    case stopTimer(UUID)
    case resetTimer(UUID)
    case sendMIDI(MIDIMessage)
    case clear(ClearTarget)
    case playMedia(MediaRef)
    case showMessage(String)
    case stageMessage(String)
    case triggerPresentation(UUID, slide: Int)
    case nextSlide
    case previousSlide
    case startSlideshow(interval: Double)
    case stopSlideshow
    case openWeb(String)
    case delay(Double)

    var summary: String {
        switch self {
        case .triggerMacro: "Run Macro"
        case .setLook: "Set Look"
        case .showProp: "Show Prop"
        case .hideProp: "Hide Prop"
        case .startTimer: "Start Timer"
        case .stopTimer: "Stop Timer"
        case .resetTimer: "Reset Timer"
        case .sendMIDI(let m): "MIDI: \(m.summary)"
        case .clear(let t): t.title
        case .playMedia(let m): "Play \(m.displayName)"
        case .showMessage(let s): "Message: \(s)"
        case .stageMessage(let s): "Stage: \(s)"
        case .triggerPresentation: "Trigger Slide"
        case .nextSlide: "Next Slide"
        case .previousSlide: "Previous Slide"
        case .startSlideshow(let i): "Slideshow every \(Int(i))s"
        case .stopSlideshow: "Stop Slideshow"
        case .openWeb(let u): "Browser: \(u)"
        case .delay(let s): "Wait \(String(format: "%.1f", s))s"
        }
    }
}

struct Macro: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: RGBA = RGBA(hex: "#6366F1")
    var symbol: String = "bolt.fill"
    var actions: [SlideAction] = []
    /// Shown in volunteer mode.
    var volunteerVisible = true
}

// MARK: - Themes

enum HAlign: String, Codable, CaseIterable { case leading, center, trailing }
enum VAlign: String, Codable, CaseIterable { case top, middle, bottom }

struct LowerThirdStyle: Codable, Hashable {
    var barColor = RGBA(r: 0.05, g: 0.05, b: 0.08, a: 0.82)
    var accentColor = RGBA(hex: "#F59E0B")
    var textColor = RGBA.white
    var fontSize: Double = 44
    /// Fraction of frame height the bar occupies at most.
    var maxHeight: Double = 0.30
    var bottomMargin: Double = 60
    var sideMargin: Double = 120
    var cornerRadius: Double = 14
    var showReference = true
    var referenceSize: Double = 30
    var align: HAlign = .leading
}

struct Theme: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var background = RGBA.black
    var backgroundMedia: MediaRef? = nil
    var fontName: String = "Helvetica Neue"
    var fontSize: Double = 72
    var bold = true
    var textColor = RGBA.white
    var align: HAlign = .center
    var vAlign: VAlign = .middle
    var padding: Double = 120
    var lineSpacing: Double = 8
    var uppercase = false
    var shadow = true
    var outlineWidth: Double = 0
    var outlineColor = RGBA.black
    var autoFit = true
    var showLabel = false
    var labelSize: Double = 36
    var labelColor = RGBA(r: 1, g: 1, b: 1, a: 0.8)
    var maxLinesPerSlide = 2
    var lowerThird = LowerThirdStyle()
}

// MARK: - Screens & looks

enum ScreenRole: String, Codable, CaseIterable, Identifiable {
    case audience, stream, stage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audience: "Audience"
        case .stream: "Livestream"
        case .stage: "Stage Display"
        }
    }
}

enum VideoMode: String, Codable, CaseIterable, Identifiable {
    case hd1080p2997, hd1080p30, hd1080p5994, hd1080p60, hd1080i5994, hd1080p25, hd1080i50, hd720p5994, uhd2160p2997, uhd2160p5994
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hd1080p2997: "1080p29.97"
        case .hd1080p30: "1080p30"
        case .hd1080p5994: "1080p59.94"
        case .hd1080p60: "1080p60"
        case .hd1080i5994: "1080i59.94"
        case .hd1080p25: "1080p25"
        case .hd1080i50: "1080i50"
        case .hd720p5994: "720p59.94"
        case .uhd2160p2997: "2160p29.97"
        case .uhd2160p5994: "2160p59.94"
        }
    }
    var size: CGSize {
        switch self {
        case .hd720p5994: CGSize(width: 1280, height: 720)
        case .uhd2160p2997, .uhd2160p5994: CGSize(width: 3840, height: 2160)
        default: CGSize(width: 1920, height: 1080)
        }
    }
    var fps: Double {
        switch self {
        case .hd1080p2997, .uhd2160p2997, .hd1080i5994: 29.97
        case .hd1080p30: 30
        case .hd1080p5994, .hd720p5994, .uhd2160p5994: 59.94
        case .hd1080p60: 60
        case .hd1080p25, .hd1080i50: 25
        }
    }
}

enum ScreenDestination: Codable, Hashable {
    case none
    /// A Mac display by its CGDirectDisplayID (stored with the name for re-matching after reboot).
    case display(id: UInt32, name: String)
    case window
    case decklink(device: String, mode: VideoMode, keyer: Bool)
    case ndi(name: String)

    var summary: String {
        switch self {
        case .none: "Not assigned"
        case .display(_, let name): "Display: \(name)"
        case .window: "Floating window"
        case .decklink(let d, let m, let k): "DeckLink \(d) • \(m.title)\(k ? " • Fill+Key" : "")"
        case .ndi(let n): "NDI: \(n)"
        }
    }
}

struct Screen: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var role: ScreenRole
    var destinations: [ScreenDestination] = []
    var width: Int = 1920
    var height: Int = 1080
    var fps: Double = 30
    var enabled = true
    var stageLayoutID: UUID? = nil

    var size: CGSize { CGSize(width: width, height: height) }
}

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    /// Full 1920x1080 slide with theme background.
    case fullSlide
    /// Theme text with no background — transparent for keying over cameras.
    case transparentText
    /// Lower-third bar with text, transparent elsewhere.
    case lowerThird
    /// Nothing from the slide layer.
    case hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullSlide: "Full Slide (takeover)"
        case .transparentText: "Transparent Text"
        case .lowerThird: "Lower Third"
        case .hidden: "Hidden"
        }
    }
}

struct LayerSet: Codable, Hashable {
    var background = true
    var slide = true
    var props = true
    var messages = true
    var liveVideo = true
}

struct ScreenLookConfig: Codable, Hashable {
    var layers = LayerSet()
    var defaultMode: RenderMode = .fullSlide
    /// Per-presentation-kind overrides, e.g. scripture → lowerThird on the stream.
    var modeByKind: [PresentationKind: RenderMode] = [:]
    /// Per-kind theme override applied on this screen (e.g. the "Bible lower third" theme).
    var themeByKind: [PresentationKind: UUID] = [:]

    func mode(for kind: PresentationKind?) -> RenderMode {
        guard let kind, let m = modeByKind[kind] else { return defaultMode }
        return m
    }
}

struct Look: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var screens: [UUID: ScreenLookConfig] = [:]

    func config(for screenID: UUID) -> ScreenLookConfig { screens[screenID] ?? ScreenLookConfig() }
}

// MARK: - Props / lower thirds

enum PropKind: String, Codable, CaseIterable { case lowerThird, image, text }

struct Prop: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: PropKind = .lowerThird
    var title: String = ""
    var subtitle: String = ""
    var media: MediaRef? = nil
    var style = LowerThirdStyle()
    var autoHideSeconds: Double = 0
}

// MARK: - Timers

enum TimerKind: Codable, Hashable {
    case countdown(seconds: Double)
    case countdownTo(hour: Int, minute: Int)
    case elapsed
}

struct ServiceTimer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: TimerKind
    var allowOverrun = true
}

// MARK: - Stage

enum ChordStyle: String, Codable, CaseIterable, Identifiable {
    case nashville, letters, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nashville: "Nashville Numbers"
        case .letters: "Chord Letters"
        case .both: "Numbers + Letters"
        }
    }
}

struct StageLayout: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var showCurrent = true
    var showNext = true
    var showClock = true
    var showNotes = false
    var showMessage = true
    var timerIDs: [UUID] = []
    var textScale: Double = 1
    var background = RGBA.black
    var currentColor = RGBA.white
    var nextColor = RGBA(hex: "#FACC15")
    /// Show chords above lyrics (optional so older libraries decode).
    var showChords: Bool? = nil
    var chordStyle: ChordStyle? = nil
    var chordColor: RGBA? = nil
}

// MARK: - Playlists & service templates

enum PlaylistItemKind: Codable, Hashable {
    case header(String)
    case presentation(UUID)
    /// A slot that hasn't been filled yet (e.g. "Sermon" from a template before sync fills it).
    case placeholder(String)
}

struct PlaylistItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: PlaylistItemKind
    var pcoItemID: String? = nil
    var color: RGBA? = nil
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var items: [PlaylistItem] = []
    var date: Date? = nil
    var pcoPlanID: String? = nil
    var pcoServiceTypeID: String? = nil
    var pcoUpdatedAt: String? = nil
}

enum TemplateMatch: String, Codable, CaseIterable, Identifiable {
    case song, header, media, titleContains
    var id: String { rawValue }
}

enum TemplateResult: Codable, Hashable {
    /// Build a presentation from Planning Center song lyrics.
    case songLyrics
    /// Parse scripture references from the item title/description and build slides.
    case scripture
    /// Use (or create) a library presentation with this name.
    case presentationNamed(String)
    /// Always insert this specific presentation.
    case presentation(UUID)
    case header
    case placeholder
    case skip
}

struct TemplateRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var match: TemplateMatch
    var text: String = ""
    var result: TemplateResult
}

struct ServiceTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var pcoServiceTypeID: String = ""
    var rules: [TemplateRule] = ServiceTemplate.defaultRules
    /// Inserted at the start of every synced playlist (e.g. walk-in loop / countdown).
    var leadingPresentations: [UUID] = []
    var trailingPresentations: [UUID] = []

    static let defaultRules: [TemplateRule] = [
        TemplateRule(match: .song, result: .songLyrics),
        TemplateRule(match: .header, result: .header),
        TemplateRule(match: .titleContains, text: "scripture", result: .scripture),
        TemplateRule(match: .titleContains, text: "reading", result: .scripture),
        TemplateRule(match: .titleContains, text: "sermon", result: .presentationNamed("Sermon")),
        TemplateRule(match: .titleContains, text: "message", result: .presentationNamed("Sermon")),
        TemplateRule(match: .titleContains, text: "announcement", result: .presentationNamed("Announcements")),
        TemplateRule(match: .titleContains, text: "welcome", result: .presentationNamed("Welcome")),
        TemplateRule(match: .media, result: .placeholder),
    ]
}

// MARK: - Schedules

enum ScheduleWhen: Codable, Hashable {
    case once(Date)
    case weekly(weekday: Int, hour: Int, minute: Int) // weekday: 1 = Sunday
}

struct ScheduledTrigger: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var enabled = true
    var when: ScheduleWhen
    var actions: [SlideAction] = []
    var lastFired: Date? = nil
}

struct MIDIMapping: Identifiable, Codable, Hashable {
    var id = UUID()
    var message: MIDIMessage
    var actions: [SlideAction]
}
