import Foundation
import OSLog
import WidgetKit

@MainActor
final class ListeningRecorder {
    private let logger = Logger(subsystem: "local.notchplayer.app", category: "listening-history")
    private let url: URL?
    private var history = ListeningHistory()
    private var canRecord = false
    private var accumulator = ListeningAccumulator()
    private var dirty = false
    private var wasPlaying = false
    private var lastWrite = ContinuousClock.now
    private var lastReload: ContinuousClock.Instant?

    init(url: URL? = ListeningHistory.fileURL) {
        self.url = url
        guard let url else { return }
        do {
            history = try ListeningHistory.load(from: url)
            canRecord = true
        } catch {
            logger.error("Could not read listening history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sample(_ source: ListeningSource?, at date: Date, tick: ContinuousClock.Instant) {
        guard canRecord else { return }
        if accumulator.observe(source, at: date, tick: tick, history: &history) {
            dirty = true
        }
        let stopped = wasPlaying && source == nil
        wasPlaying = source != nil
        if stopped || lastWrite.duration(to: .now) >= .seconds(15) { flush() }
    }

    func interrupt() {
        accumulator.interrupt()
        wasPlaying = false
        flush()
    }

    private func flush() {
        guard dirty, let url else { return }
        lastWrite = .now
        do {
            try history.save(to: url)
            dirty = false
            if lastReload.map({ $0.duration(to: .now) >= .seconds(1200) }) ?? true {
                lastReload = .now
                WidgetCenter.shared.reloadTimelines(ofKind: ListeningHistory.widgetKind)
            }
        } catch {
            logger.error("Could not save listening history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
