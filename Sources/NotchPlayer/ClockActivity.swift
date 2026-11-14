import Foundation

struct ClockActivity: Identifiable, Equatable {
    enum Kind {
        case timer, stopwatch

        var title: String { self == .timer ? "Timer" : "Stopwatch" }
        var symbol: String { self == .timer ? "timer" : "stopwatch" }
    }

    enum Timing: Equatable {
        case countdown(Date)
        case countingUp(since: Date, offset: TimeInterval)
        case paused(TimeInterval)
    }

    let id: String
    let kind: Kind
    let title: String
    let timing: Timing

    var isPaused: Bool {
        if case .paused = timing { return true }
        return false
    }

    func displayTime(at date: Date) -> String {
        let interval: TimeInterval
        switch timing {
        case .countdown(let deadline): interval = ceil(deadline.timeIntervalSince(date))
        case .countingUp(let start, let offset): interval = floor(date.timeIntervalSince(start) + offset)
        case .paused(let seconds): interval = kind == .timer ? ceil(seconds) : floor(seconds)
        }
        let seconds = Int(min(max(interval, 0), Double(Int32.max)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func isActive(at date: Date) -> Bool {
        if case .countdown(let deadline) = timing { return deadline > date }
        return true
    }
}

struct ClockActivityReader {
    private typealias Record = [String: Any]
    private let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.mobiletimerd.plist")
    private var lastData: Data?
    private var activities: [ClockActivity] = []

    mutating func read(at now: Date = Date()) -> [ClockActivity] {
        guard let data = try? Data(contentsOf: store) else {
            lastData = nil
            activities = []
            return []
        }
        if data != lastData {
            lastData = data
            activities = Self.decode(data)
        }
        return activities.filter { $0.isActive(at: now) }
    }

    // Clock persists dates and offsets in mobiletimerd's preferences, including
    // activities whose Clock window or tab is closed.
    static func decode(_ data: Data) -> [ClockActivity] {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? Record else {
            return []
        }
        let timers = records("MTTimers", in: root)
            .compactMap { $0["$MTTimer"] as? Record }
            .compactMap(timer)
        let stopwatches = records("MTStopwatches", in: root)
            .compactMap { $0["$MTStopwatch"] as? Record }
            .compactMap(stopwatch)

        // Put the next running timer first, followed by the running stopwatch
        // and paused activities.
        return (timers + stopwatches).sorted {
            switch ($0.timing, $1.timing) {
            case let (.countdown(lhs), .countdown(rhs)) where lhs != rhs: return lhs < rhs
            case (.countdown, .countdown): break
            case (.countdown, _): return true
            case (_, .countdown): return false
            default:
                if $0.isPaused != $1.isPaused { return !$0.isPaused }
            }
            return $0.id < $1.id
        }
    }

    private static func records(_ key: String, in root: Record) -> [Record] {
        (root[key] as? Record)?[key] as? [Record] ?? []
    }

    private static func timer(_ record: Record) -> ClockActivity? {
        guard let id = record["MTTimerID"] as? String,
              let fireTime = record["MTTimerFireTime"] as? Record else { return nil }
        let timing: ClockActivity.Timing
        switch record["MTTimerState"] as? Int {
        case 3:
            guard let deadline = (fireTime["$MTTimerDate"] as? Record)?["MTTimerTimeDate"] as? Date else {
                return nil
            }
            timing = .countdown(deadline)
        case 2:
            guard let remaining = (fireTime["$MTTimerTimeInterval"] as? Record)?["MTTimerTimeInterval"] as? Double,
                  remaining.isFinite, remaining > 0 else { return nil }
            timing = .paused(remaining)
        default: return nil
        }
        let title = (record["MTTimerTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ClockActivity(id: "timer-" + id, kind: .timer,
                             title: title.isEmpty || title == "CURRENT_TIMER" ? "Timer" : title, timing: timing)
    }

    private static func stopwatch(_ record: Record) -> ClockActivity? {
        guard let id = record["MTStopwatchIdentifier"] as? String else { return nil }
        let offset = record["MTStopwatchOffset"] as? Double ?? 0
        guard offset.isFinite, offset >= 0 else { return nil }
        let timing: ClockActivity.Timing
        switch record["MTStopwatchState"] as? Int {
        case 2:
            guard let start = record["MTStopwatchStartDate"] as? Date else { return nil }
            timing = .countingUp(since: start, offset: offset)
        case 1 where offset > 0:
            timing = .paused(offset)
        default: return nil
        }
        return ClockActivity(id: "stopwatch-" + id, kind: .stopwatch, title: "Stopwatch", timing: timing)
    }
}
