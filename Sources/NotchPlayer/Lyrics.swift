import SwiftUI

struct LyricLine: Equatable {
    let time: Double
    let text: String

    static func parse(_ source: String) -> [LyricLine] {
        let timestamp = #/\[(\d+):(\d{2}(?:\.\d+)?)\]/#
        return source.split(whereSeparator: \.isNewline).flatMap { line -> [LyricLine] in
            let matches = line.matches(of: timestamp)
            guard let last = matches.last else { return [] }
            let text = line[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            return matches.compactMap { match in
                guard let minutes = Double(match.1), let seconds = Double(match.2), seconds < 60 else { return nil }
                return LyricLine(time: minutes * 60 + seconds, text: text)
            }
        }.sorted { $0.time < $1.time }
    }
}

enum LyricsService {
    enum Result {
        case loading, synced([LyricLine]), plain(String), unavailable, failed
    }

    private struct Match: Decodable {
        let trackName: String
        let artistName: String
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    static func load(for track: Track) async -> Result {
        guard !track.title.isEmpty, !track.artist.isEmpty else { return .unavailable }
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "lrclib.net"
        endpoint.path = "/api/search"
        endpoint.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        guard let url = endpoint.url else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Notch Player (https://github.com/andy1924/notch-player)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let matches = try JSONDecoder().decode([Match].self, from: data).filter {
                $0.trackName.localizedCaseInsensitiveCompare(track.title) == .orderedSame
                    && $0.artistName.localizedCaseInsensitiveCompare(track.artist) == .orderedSame
                    && (track.duration <= 0 || abs(($0.duration ?? 0) - track.duration) <= 3)
            }
            for match in matches {
                let lines = LyricLine.parse(match.syncedLyrics ?? "")
                if lines.contains(where: { !$0.text.isEmpty }) { return .synced(lines) }
            }
            if let plain = matches.compactMap(\.plainLyrics).first(where: { !$0.isEmpty }) {
                return .plain(plain)
            }
            return .unavailable
        } catch {
            return .failed
        }
    }
}

private final class LyricsState: ObservableObject {
    @Published var result: LyricsService.Result = .loading
}

struct LockLyrics: View {
    @ObservedObject var playback: Playback
    let track: Track
    @StateObject private var state = LyricsState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state.result {
            case .loading: ProgressView("Loading lyrics")
            case .unavailable: Text("Lyrics unavailable for this track.")
            case .failed: Text("Couldn’t load lyrics.")
            case .plain(let lyrics):
                ScrollView {
                    Text(lyrics).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .synced(let lines):
                TimelineView(.periodic(from: .now, by: 0.18)) { _ in
                    let position = playback.position()
                    let current = lines.lastIndex { $0.time <= position } ?? -1
                    let first = max(0, current)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(first..<min(first + 3, lines.count), id: \.self) { index in
                            Text(lines[index].text.isEmpty ? "♪" : lines[index].text)
                                .foregroundStyle(.white.opacity(index == current ? 1 : (index == first ? 0.52 : 0.34)))
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: current)
                }
            }
        }
        .font(.system(size: 20, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
        .task {
            if playback.preview {
                state.result = .synced(LyricLine.parse("""
                [00:00]Streetlights fade across the glass
                [00:20]We watch the empty avenues pass
                [01:10]Blue on the dashboard, stars overhead
                [01:28]The radio hums the words we left unsaid
                [01:44]Follow the road until the morning
                [02:03]Let the city drift away
                """))
            } else {
                let result = await LyricsService.load(for: track)
                if !Task.isCancelled { state.result = result }
            }
        }
    }
}
