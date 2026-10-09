import EventKit
import Foundation
import Observation

/// Fires scheduled triggers (one-off or weekly) and calendar events at their start time.
///
/// Calendar events trigger when their notes contain lines like:
///   lumen: macro Walk In
///   lumen: slide Announcements 1
///   lumen: look Stream Takeover
///   lumen: clear all
@MainActor
@Observable
final class Scheduler {
    let store: LibraryStore
    let engine: LiveEngine

    private(set) var upcoming: [(date: Date, name: String)] = []
    private(set) var calendarAccess = false
    private(set) var lastFired: String = ""

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private var firedCalendarEvents: Set<String> = []
    @ObservationIgnored private var lastCheck = Date()
    @ObservationIgnored private var lastCalendarCheck = Date()

    init(store: LibraryStore, engine: LiveEngine) {
        self.store = store
        self.engine = engine
    }

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep firing while a menu is open or an alert is showing
        timer = t
        if store.data.settings.calendarTriggersEnabled { Task { await requestCalendar() } }
    }

    func requestCalendar() async {
        calendarAccess = (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    static func nextDate(_ when: ScheduleWhen, after: Date) -> Date? {
        switch when {
        case .once(let d): return d > after ? d : nil
        case .weekly(let wd, let h, let m):
            return Calendar.current.nextDate(after: after, matching: DateComponents(hour: h, minute: m, second: 0, weekday: wd),
                                             matchingPolicy: .nextTime)
        }
    }

    /// A trigger more than this late is skipped, not run. After the Mac sleeps through 9:30, a "walk-in" macro must not
    /// suddenly fire at 12:00 when it wakes.
    static let maxLateness: TimeInterval = 90

    enum Due: Equatable { case none, fire(Date), missed(Date) }

    /// What `when` should do given the check window (since, now].
    static func due(_ when: ScheduleWhen, since: Date, now: Date) -> Due {
        guard let d = nextDate(when, after: since), d <= now else { return .none }
        return now.timeIntervalSince(d) <= maxLateness ? .fire(d) : .missed(d)
    }

    private func check() {
        let now = Date()
        let since = lastCheck
        lastCheck = now
        for (i, s) in store.data.schedules.enumerated() where s.enabled {
            switch Self.due(s.when, since: since, now: now) {
            case .none: break
            case .fire:
                store.data.schedules[i].lastFired = now
                lastFired = "\(s.name) at \(now.formatted(date: .omitted, time: .shortened))"
                engine.run(s.actions)
            case .missed(let d):
                lastFired = "Skipped \(s.name): it was due at \(d.formatted(date: .omitted, time: .shortened)) and Lumen wasn't running or awake"
            }
        }
        if store.data.settings.calendarTriggersEnabled, calendarAccess, now.timeIntervalSince(lastCalendarCheck) >= 5 {
            // EventKit queries run on the main thread: do it every few seconds, over the whole gap since last time.
            let from = max(lastCalendarCheck, now.addingTimeInterval(-Self.maxLateness))
            lastCalendarCheck = now
            checkCalendar(from: from, now: now)
        }
        if Int(now.timeIntervalSince1970) % 30 == 0 { refreshUpcoming() }
    }

    private func checkCalendar(from: Date, now: Date) {
        let cals = calendars()
        let pred = eventStore.predicateForEvents(withStart: from, end: now.addingTimeInterval(1), calendars: cals)
        for ev in eventStore.events(matching: pred) {
            guard let start = ev.startDate, start <= now, start >= from else { continue }
            let key = "\(ev.calendarItemIdentifier)|\(start.timeIntervalSince1970)"
            guard !firedCalendarEvents.contains(key) else { continue }
            let actions = Self.actions(fromNotes: ev.notes ?? "", store: store)
            guard !actions.isEmpty else { continue }
            firedCalendarEvents.insert(key)
            lastFired = "Calendar: \(ev.title ?? "event")"
            engine.run(actions)
        }
    }

    private func calendars() -> [EKCalendar]? {
        let name = store.data.settings.calendarName
        guard !name.isEmpty else { return nil }
        let c = eventStore.calendars(for: .event).filter { $0.title == name }
        return c.isEmpty ? nil : c
    }

    static func actions(fromNotes notes: String, store: LibraryStore) -> [SlideAction] {
        var out: [SlideAction] = []
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("lumen:") else { continue }
            let rest = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let verb = parts.first?.lowercased() else { continue }
            let arg = parts.count > 1 ? parts[1] : ""
            func named<T>(_ list: [T], _ name: (T) -> String) -> T? {
                list.first { name($0).caseInsensitiveCompare(arg) == .orderedSame }
            }
            switch verb {
            case "macro": if let m = named(store.data.macros, { $0.name }) { out.append(.triggerMacro(m.id)) }
            case "look": if let l = named(store.data.looks, { $0.name }) { out.append(.setLook(l.id)) }
            case "clear": out.append(.clear(ClearTarget(rawValue: arg.lowercased()) ?? .all))
            case "message": out.append(.showMessage(arg))
            case "slide", "presentation":
                // "Announcements 3" → slide 3 of "Announcements"
                var name = arg, index = 0
                if let last = arg.split(separator: " ").last, let n = Int(last) {
                    index = max(0, n - 1)
                    name = String(arg.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
                }
                if let p = store.data.presentations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    out.append(.triggerPresentation(p.id, slide: index))
                }
            case "timer":
                if let t = named(store.data.timers, { $0.name }) { out.append(.resetTimer(t.id)); out.append(.startTimer(t.id)) }
            default: break
            }
        }
        return out
    }

    func refreshUpcoming() {
        let now = Date()
        var list: [(Date, String)] = store.data.schedules.filter(\.enabled).compactMap { s in
            Self.nextDate(s.when, after: now).map { ($0, s.name) }
        }
        if store.data.settings.calendarTriggersEnabled, calendarAccess {
            let pred = eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(7 * 86400), calendars: calendars())
            for ev in eventStore.events(matching: pred) where !Self.actions(fromNotes: ev.notes ?? "", store: store).isEmpty {
                list.append((ev.startDate, "📅 " + (ev.title ?? "Event")))
            }
        }
        upcoming = list.sorted { $0.0 < $1.0 }.prefix(12).map { (date: $0.0, name: $0.1) }
    }
}
