import Foundation

enum ListeningSource: String, Codable {
    case music, spotify
}

struct ListeningTotals: Codable, Equatable {
    var music: TimeInterval = 0
    var spotify: TimeInterval = 0
    var total: TimeInterval { music + spotify }

    mutating func add(_ seconds: TimeInterval, source: ListeningSource) {
        switch source {
        case .music: music += seconds
        case .spotify: spotify += seconds
        }
    }

    mutating func merge(_ other: Self) {
        music += other.music
        spotify += other.spotify
    }
}

struct ListeningHistory: Codable {
    static let widgetKind = "local.notchplayer.app.listening-time"
    private(set) var hours: [Int: ListeningTotals] = [:]

    // WidgetKit runs in a sandbox whose Foundation home directory can point at its container.
    static let fileURL: URL? = {
        guard let user = getpwuid(getuid()), let path = user.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Notch Player/Listening History", isDirectory: true)
            .appendingPathComponent("hours.json")
    }()

    static func load(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    mutating func record(from start: Date, to end: Date, source: ListeningSource, calendar: Calendar = .current) {
        var cursor = start
        while cursor < end, let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor {
            let next = min(hour.end, end)
            let key = Int(hour.start.timeIntervalSince1970)
            hours[key, default: ListeningTotals()].add(next.timeIntervalSince(cursor), source: source)
            cursor = next
        }
    }

    func totals(in interval: DateInterval) -> ListeningTotals {
        hours.reduce(into: ListeningTotals()) { result, bucket in
            let start = Date(timeIntervalSince1970: Double(bucket.key))
            if start >= interval.start && start < interval.end { result.merge(bucket.value) }
        }
    }

    func recentDays(endingAt date: Date, calendar: Calendar = .current) -> [ListeningDay] {
        let today = calendar.startOfDay(for: date)
        return (-6...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
            return ListeningDay(date: day, totals: totals(in: interval))
        }
    }

    func todayHours(at date: Date, calendar: Calendar = .current) -> [ListeningTotals] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        return stride(from: day.start.timeIntervalSince1970, to: day.end.timeIntervalSince1970, by: 3600).map {
            hours[Int($0)] ?? ListeningTotals()
        }
    }
}

struct ListeningDay: Identifiable {
    let date: Date
    let totals: ListeningTotals
    var id: Date { date }
}

struct ListeningAccumulator {
    private var previous: (date: Date, tick: ContinuousClock.Instant, source: ListeningSource?)?

    mutating func observe(_ source: ListeningSource?, at date: Date, tick: ContinuousClock.Instant,
                          history: inout ListeningHistory, calendar: Calendar = .current) -> Bool {
        let last = previous
        previous = (date, tick, source)
        guard let last, let playing = last.source else { return false }
        let wallSeconds = date.timeIntervalSince(last.date)
        let elapsed = last.tick.duration(to: tick)
        let parts = elapsed.components
        let monotonicSeconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard wallSeconds > 0, wallSeconds <= 8, monotonicSeconds > 0, abs(wallSeconds - monotonicSeconds) < 1 else {
            return false
        }
        history.record(from: last.date, to: date, source: playing, calendar: calendar)
        return true
    }

    mutating func interrupt() { previous = nil }
}
