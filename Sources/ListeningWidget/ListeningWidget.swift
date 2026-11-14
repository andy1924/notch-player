import SwiftUI
import WidgetKit

struct ListeningEntry: TimelineEntry {
    let date: Date
    let history: ListeningHistory
    var readable = true
}

struct ListeningTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry { sample }

    func getSnapshot(in context: Context, completion: @escaping (ListeningEntry) -> Void) {
        completion(context.isPreview ? sample : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningEntry>) -> Void) {
        let entry = current()
        let nextRefresh = entry.date.addingTimeInterval(20 * 60)
        let midnight = Calendar.current.dateInterval(of: .day, for: entry.date)?.end ?? nextRefresh
        completion(Timeline(entries: [entry], policy: .after(min(nextRefresh, midnight))))
    }

    private func current() -> ListeningEntry {
        let now = Date()
        if let url = ListeningHistory.fileURL, let history = try? ListeningHistory.load(from: url) {
            return ListeningEntry(date: now, history: history)
        }
        return ListeningEntry(date: now, history: ListeningHistory(), readable: false)
    }

    private var sample: ListeningEntry {
        let calendar = Calendar.current
        // Anchor the preview after midday so it remains legible even just after midnight.
        let today = calendar.startOfDay(for: .now)
        let previewDate = calendar.date(byAdding: .hour, value: 16, to: today) ?? .now
        var history = ListeningHistory()
        for (index, minutes) in [32, 57, 19, 72, 42, 85, 68].enumerated() {
            guard let day = calendar.date(byAdding: .day, value: index - 6, to: today) else { continue }
            let morning = day.addingTimeInterval(9 * 3600)
            let afternoon = day.addingTimeInterval(14 * 3600)
            history.record(from: morning, to: morning.addingTimeInterval(Double(minutes / 2) * 60), source: .music)
            history.record(from: afternoon, to: afternoon.addingTimeInterval(Double(minutes - minutes / 2) * 60), source: .spotify)
        }
        return ListeningEntry(date: previewDate, history: history)
    }
}

struct ListeningWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ListeningEntry

    private let accent = Color(red: 0.24, green: 0.58, blue: 0.98)

    var body: some View {
        Group {
            if !entry.readable {
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    Text("Listening history unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if family == .systemMedium {
                let days = entry.history.recentDays(endingAt: entry.date)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        summary(days.last?.totals.total ?? 0)
                        Spacer(minLength: 4)
                        Text("Past 7 days")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(duration(days.reduce(0) { $0 + $1.totals.total }))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 105, alignment: .leading)

                    VStack(alignment: .leading, spacing: 5) {
                        chart(days.map(\.totals.total), floor: 1800, height: 64, highlightToday: true)
                            .accessibilityLabel("Listening by day")
                            .accessibilityValue(days.map {
                                "\($0.date.formatted(.dateTime.weekday(.abbreviated))) \(duration($0.totals.total))"
                            }.joined(separator: ", "))
                        HStack(spacing: 3) {
                            ForEach(days) { day in
                                Text(day.date.formatted(.dateTime.weekday(.narrow)))
                                    .foregroundStyle(day.id == days.last?.id ? .primary : .secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .font(.system(size: 9, weight: .medium))
                        .accessibilityHidden(true)
                    }
                }
            } else {
                let hours = entry.history.todayHours(at: entry.date)
                VStack(alignment: .leading, spacing: 5) {
                    summary(hours.reduce(0) { $0 + $1.total })
                    Spacer(minLength: 4)
                    chart(hours.map(\.total), floor: 900, height: 32, highlightToday: false)
                        .accessibilityHidden(true)
                    HStack {
                        Text("12 AM")
                        Spacer()
                        Text("12 PM")
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var heading: some View {
        Label("Listening Time", systemImage: "waveform")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func summary(_ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading
            Text(duration(seconds))
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityLabel("\(duration(seconds)) listened today")
            Text("Today")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func chart(_ values: [TimeInterval], floor: TimeInterval, height: CGFloat,
                       highlightToday: Bool) -> some View {
        let maximum = max(floor, values.max() ?? 0)
        return HStack(alignment: .bottom, spacing: highlightToday ? 4 : 1.5) {
            ForEach(values.indices, id: \.self) { index in
                let value = values[index]
                RoundedRectangle(cornerRadius: highlightToday ? 3 : 1)
                    .fill(value == 0 ? Color.secondary.opacity(0.18)
                          : accent.opacity(highlightToday && index < values.count - 1 ? 0.58 : 1))
                    .widgetAccentable()
                    .frame(height: max(2, height * value / maximum))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes == 0, seconds > 0 { return "<1m" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

@main
struct ListeningTimeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ListeningHistory.widgetKind, provider: ListeningTimeline()) { entry in
            ListeningWidgetView(entry: entry)
        }
        .configurationDisplayName("Listening Time")
        .description("See today’s music listening time and your recent activity.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
