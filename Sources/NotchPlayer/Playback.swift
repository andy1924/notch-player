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
    case previous
    case toggle
    case next
}

private enum PlayerScript {
    static let source = """
    function run(argv) {
        const app = Application(argv[0]);
        if (!app.running()) return "null";
        switch (argv[1]) {
        case "previous": app.previousTrack(); break;
        case "toggle": app.playpause(); break;
        case "next": app.nextTrack(); break;
        case "seek": app.playerPosition = Number(argv[3]); break;
        case "read": return readTrack(app, argv[2] === "com.spotify.client");
        default: throw new Error("Unknown playback action");
        }
        return "";
    }

    function readTrack(app, spotify) {

        const state = app.playerState();
        if (state !== "playing" && state !== "paused") return "null";
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

    static func run(_ player: Player, path: String, action: String, position: Double? = nil) -> Data? {
        let arguments = ["-l", "JavaScript", "-e", source, path, action, player.rawValue]
        return execute(arguments + (position.map { [String($0)] } ?? []))
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
    @Published private(set) var controlError: String?
    let preview: Bool
    var didUpdate: (() -> Void)?

    private let scripts = DispatchQueue(label: "local.notchplayer.playback")
    private var timer: Timer?
    private var refreshInFlight = false
    private var lastSuccessfulSample = ContinuousClock.now
    private var artTask: Task<Void, Never>?
    private var sampledAt = ContinuousClock.now
    private var demoIndex = 0
    private let demoTracks = [
        (title: "Night Drive", duration: 234.0),
        (title: "Blue Hour", duration: 201.0),
        (title: "First Light", duration: 246.0)
    ]

    init(preview: Bool) {
        self.preview = preview
        if preview {
            player = .music
            updateDemo(position: 72, playing: true)
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
            switch command {
            case .previous:
                demoIndex = (demoIndex + demoTracks.count - 1) % demoTracks.count
                updateDemo(position: 0, playing: track.playing)
            case .next:
                demoIndex = (demoIndex + 1) % demoTracks.count
                updateDemo(position: 0, playing: track.playing)
            case .toggle:
                updateDemo(position: position(), playing: !track.playing)
            }
            return
        }
        perform(command.rawValue)
    }

    func seek(to position: Double) {
        guard let track, track.duration.isFinite, track.duration > 0, position.isFinite else { return }
        let target = min(max(0, position), track.duration)
        if preview {
            updateDemo(position: target, playing: track.playing)
        } else {
            perform("seek", position: target)
        }
    }

    func openPlayer() {
        guard !preview, let player else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else {
            controlError = "Couldn’t find \(player.name)."
            return
        }
        controlError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.controlError = "Couldn’t open \(player.name)." }
        }
    }

    private func updateDemo(position: Double, playing: Bool) {
        let demo = demoTracks[demoIndex]
        track = Track(id: "preview-\(demoIndex)", title: demo.title, artist: "Notch Player Demo",
                      duration: demo.duration, position: position, playing: playing, artworkURL: "")
        sampledAt = .now
        didUpdate?()
    }

    private func perform(_ action: String, position: Double? = nil) {
        guard let player, let path = player.runningPath else { return }
        controlError = nil
        scripts.async { [weak self] in
            let success = PlayerScript.run(player, path: path, action: action, position: position) != nil
            Task { @MainActor in
                guard let self else { return }
                if !success, self.player == player { self.controlError = "Couldn’t control \(player.name)." }
                self.refresh()
            }
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
            var failed: Set<Player> = []
            for (player, path) in running {
                guard let data = PlayerScript.run(player, path: path, action: "read") else {
                    failed.insert(player)
                    continue
                }
                do {
                    if let track = try JSONDecoder().decode(Track?.self, from: data) {
                        candidates.append((player, track, .now))
                    }
                } catch {
                    failed.insert(player)
                }
            }
            let active = candidates.filter { $0.1.playing }
            let available = active.isEmpty ? candidates : active
            let selected = available.first { $0.0 == currentPlayer } ?? available.first
            Task { @MainActor in
                guard let self else { return }
                self.refreshInFlight = false
                // A brief Automation failure during display lock or wake should not remove the player.
                if selected == nil, let currentPlayer, failed.contains(currentPlayer),
                   self.track != nil, self.lastSuccessfulSample.duration(to: .now) < .seconds(8) {
                    return
                }
                self.unavailable = !failed.isEmpty && selected == nil
                if selected != nil { self.lastSuccessfulSample = .now }
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
            controlError = nil
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
