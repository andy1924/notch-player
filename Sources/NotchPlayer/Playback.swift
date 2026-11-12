import AppKit
import SwiftUI

enum Player: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var name: String { self == .spotify ? "Spotify" : "Apple Music" }

    var runningPath: String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: rawValue)
            .first { !$0.isTerminated }?.bundleURL?.path
    }
}

struct Track: Decodable {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    let position: Double
    let playing: Bool
    let artworkURL: String
}

enum PlaybackCommand: String {
    case previous = "previousTrack"
    case toggle = "playpause"
    case next = "nextTrack"
}

private enum PlayerScript {
    static let source = """
    function run(argv) {
        const app = Application(argv[0]);
        if (!app.running()) return "null";
        if (argv[1] !== "read") {
            app[argv[1]]();
            return "";
        }

        const state = app.playerState();
        if (state !== "playing" && state !== "paused") return "null";
        const spotify = argv[2] === "com.spotify.client";
        const track = app.currentTrack();
        const optional = (get, fallback) => {
            try { return get() ?? fallback; } catch (_) { return fallback; }
        };
        const title = track.name();
        const artist = optional(() => track.artist(), "");
        const id = optional(() => spotify ? track.id() : track.persistentID(), title + artist);
        return JSON.stringify({
            id, title, artist,
            duration: optional(() => track.duration() / (spotify ? 1000 : 1), 0),
            position: optional(() => app.playerPosition(), 0),
            playing: state === "playing",
            artworkURL: spotify ? (optional(() => track.artworkUrl(), "") || optional(() => track.artworkURL(), "")) : ""
        });
    }
    """

    static func run(_ player: Player, path: String, action: String) -> Data? {
        execute(["-l", "JavaScript", "-e", source, path, action, player.rawValue])
    }

    static func musicArtwork(id: String) -> Data? {
        // Check the track again so a skip during artwork loading cannot attach the wrong cover.
        let source = """
        on run argv
            if application "/System/Applications/Music.app" is not running then return missing value
            tell application "/System/Applications/Music.app"
                if persistent ID of current track is item 1 of argv then
                    return raw data of artwork 1 of current track
                end if
            end tell
            return missing value
        end run
        """
        guard let data = execute(["-s", "s", "-e", source, id]),
              let output = String(data: data, encoding: .utf8),
              output.hasPrefix("«data "),
              let end = output.lastIndex(of: "»"),
              output.distance(from: output.startIndex, to: end) >= 10 else { return nil }

        // osascript's source form prefixes the hex bytes with a four-character type code.
        let bytes = Array(output[output.index(output.startIndex, offsetBy: 10)..<end].utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }

        var image = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            image.append(high * 16 + low)
        }
        return image
    }

    private static func execute(_ arguments: [String]) -> Data? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        defer { deadline.cancel() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

@MainActor
final class Playback: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var player: Player?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var unavailable = false
    let preview: Bool
    var didUpdate: (() -> Void)?

    private let scripts = DispatchQueue(label: "local.notchplayer.playback")
    private var timer: Timer?
    private var refreshInFlight = false
    private var artTask: Task<Void, Never>?
    private var sampledAt = ContinuousClock.now

    init(preview: Bool) {
        self.preview = preview
        if preview {
            player = .music
            track = Track(id: "preview", title: "Night Drive", artist: "Notch Player Demo",
                          duration: 234, position: 72, playing: true, artworkURL: "")
        }
    }

    func start() {
        guard !preview else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func position() -> Double {
        guard let track else { return 0 }
        let elapsed = sampledAt.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let position = max(0, track.position + (track.playing ? seconds : 0))
        return track.duration > 0 ? min(position, track.duration) : position
    }

    func send(_ command: PlaybackCommand) {
        if preview, let track {
            let position = command == .toggle ? self.position() : 0
            self.track = Track(id: track.id, title: track.title, artist: track.artist,
                               duration: track.duration, position: position,
                               playing: command == .toggle ? !track.playing : track.playing,
                               artworkURL: "")
            sampledAt = .now
            didUpdate?()
            return
        }
        guard let player, let path = player.runningPath else { return }
        scripts.async { [weak self] in
            _ = PlayerScript.run(player, path: path, action: command.rawValue)
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !preview, !refreshInFlight else { return }
        refreshInFlight = true
        let currentPlayer = player
        let running = Player.allCases.compactMap { player in
            player.runningPath.map { (player, $0) }
        }
        scripts.async { [weak self] in
            var candidates: [(Player, Track, ContinuousClock.Instant)] = []
            var failed = false
            for (player, path) in running {
                guard let data = PlayerScript.run(player, path: path, action: "read") else {
                    failed = true
                    continue
                }
                do {
                    if let track = try JSONDecoder().decode(Track?.self, from: data) {
                        candidates.append((player, track, .now))
                    }
                } catch {
                    failed = true
                }
            }
            let active = candidates.filter { $0.1.playing }
            let available = active.isEmpty ? candidates : active
            let selected = available.first { $0.0 == currentPlayer } ?? available.first
            let unavailable = failed && selected == nil
            Task { @MainActor in
                guard let self else { return }
                self.refreshInFlight = false
                self.unavailable = unavailable
                self.apply(selected)
            }
        }
    }

    private func apply(_ selection: (Player, Track, ContinuousClock.Instant)?) {
        let changed = player != selection?.0 || track?.id != selection?.1.id
            || track?.artworkURL != selection?.1.artworkURL
        player = selection?.0
        track = selection?.1
        sampledAt = selection?.2 ?? .now
        if changed {
            artTask?.cancel()
            artwork = nil
            if let (player, track, _) = selection { loadArtwork(player, track) }
        }
        didUpdate?()
    }

    private func loadArtwork(_ player: Player, _ track: Track) {
        artTask = Task { [weak self] in
            let data: Data?
            if player == .spotify {
                guard let url = URL(string: track.artworkURL), url.scheme == "https" else { return }
                data = try? await URLSession.shared.data(from: url).0
            } else {
                data = await Task.detached(priority: .utility) {
                    PlayerScript.musicArtwork(id: track.id)
                }.value
            }
            guard !Task.isCancelled, let data else { return }
            self?.artwork = NSImage(data: data)
        }
    }
}
