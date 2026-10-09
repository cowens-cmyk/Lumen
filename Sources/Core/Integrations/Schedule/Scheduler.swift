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

    init(store: LibraryStore, engine: LiveEngine) {
        self.store = store
        self.engine = engine
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
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

    private func check() {
        let now = Date()
        let since = lastCheck
        lastCheck = now
        // Anything whose fire time fell inside (since, now] fires once.
        for (i, s) in store.data.schedules.enumerated() where s.enabled {
            if let d = Self.nextDate(s.when, after: since.addingTimeInterval(-0.001)), d <= now, d > since.addingTimeInterval(-1.5) {
                store.data.schedules[i].lastFired = now
                lastFired = "\(s.name) at \(now.formatted(date: .omitted, time: .shortened))"
                Task { await engine.perform(s.actions) }
            }
        }
        if store.data.settings.calendarTriggersEnabled, calendarAccess {
            checkCalendar(now: now)
        }
        if Int(now.timeIntervalSince1970) % 30 == 0 { refreshUpcoming() }
    }

    private func checkCalendar(now: Date) {
        let cals = calendars()
        let pred = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-5), end: now.addingTimeInterval(1), calendars: cals)
        for ev in eventStore.events(matching: pred) {
            guard let start = ev.startDate, start <= now, now.timeIntervalSince(start) < 3 else { continue }
            let key = "\(ev.calendarItemIdentifier)|\(start.timeIntervalSince1970)"
            guard !firedCalendarEvents.contains(key) else { continue }
            let actions = Self.actions(fromNotes: ev.notes ?? "", store: store)
            guard !actions.isEmpty else { continue }
            firedCalendarEvents.insert(key)
            lastFired = "Calendar: \(ev.title ?? "event")"
            Task { await engine.perform(actions) }
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
