import Foundation

struct TimerRuntime: Hashable {
    var running = false
    var startedAt: Date? = nil
    var accumulated: TimeInterval = 0

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (running ? now.timeIntervalSince(startedAt ?? now) : 0)
    }

    /// Seconds to display: remaining for countdowns (may go negative), elapsed for stopwatches.
    func value(for timer: ServiceTimer, at now: Date) -> TimeInterval {
        switch timer.kind {
        case .countdown(let total):
            let v = total - elapsed(at: now)
            return timer.allowOverrun ? v : max(0, v)
        case .countdownTo(let h, let m):
            let cal = Calendar.current
            var target = cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
            // If the target time already passed by more than 6h, it means tomorrow.
            if now.timeIntervalSince(target) > 6 * 3600 { target = cal.date(byAdding: .day, value: 1, to: target)! }
            let v = target.timeIntervalSince(now)
            return timer.allowOverrun ? v : max(0, v)
        case .elapsed:
            return elapsed(at: now)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let neg = seconds < 0
        let s = Int(abs(seconds).rounded(neg ? .up : .down))
        let str = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                            : String(format: "%d:%02d", s / 60, s % 60)
        return neg ? "-" + str : str
    }
}
