import AppKit
import SwiftUI

struct NotchShape: Shape {
    let floating: Bool
    var expansion: CGFloat
    static let expandedShoulder: CGFloat = 12

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(22 + 12 * expansion, rect.height * 0.5)
        if floating { return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect) }
        let shoulder = 6 + (Self.expandedShoulder - 6) * expansion
        let left = shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addQuadCurve(to: CGPoint(x: right, y: shoulder), control: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: rect.maxY),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - radius),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: shoulder))
        path.addQuadCurve(to: .zero, control: CGPoint(x: left, y: 0))
        path.closeSubpath()
        return path
    }
}

final class NotchHover: ObservableObject {
    @Published var isHighlighted = false
}

final class NotchPages: ObservableObject {
    @Published var weather = false
}

struct NotchView: View {
    static let clockRowHeight: CGFloat = 53

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var playback: Playback
    let topHeight: CGFloat
    let floating: Bool
    let expanded: Bool
    let clockActivities: [ClockActivity]
    let compactClockFits: Bool
    let openClock: () -> Void
    let full: Bool
    let glass: Bool
    @ObservedObject var pages: NotchPages
    let openWeather: () -> Void
    let toggleFull: () -> Void
    @ObservedObject var hover: NotchHover
    let open: () -> Void
    let openArtwork: () -> Void
    let dragArtwork: (CGPoint, Bool) -> Void

    var body: some View {
        let shape = NotchShape(floating: floating, expansion: expanded ? 1 : 0)
        VStack(spacing: 0) {
            if expanded {
                Color.clear
                    .frame(height: topHeight)
                    .accessibilityHidden(true)
                clockActivityRow
            } else {
                Button(action: open) {
                    HStack {
                        if let activity = clockActivities.first {
                            if playback.track != nil {
                                CoverView(playback: playback, size: 18)
                            } else {
                                clockSymbol(activity)
                                    .frame(width: 18)
                            }
                            Spacer(minLength: 0)
                            if compactClockFits {
                                clockTime(activity, size: 12)
                            } else if playback.track != nil {
                                clockSymbol(activity)
                                    .frame(width: 18)
                            }
                        } else if playback.track != nil {
                            CoverView(playback: playback, size: 18)
                            Spacer()
                            Equalizer(playing: playback.track?.playing == true)
                        } else if floating {
                            Spacer()
                            Image(systemName: "waveform")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                            Spacer()
                        } else {
                            Color.clear
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity)
                    .frame(height: topHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand notch player")
                .accessibilityValue(clockActivities.first?.title ?? "")
                .transition(.identity)
            }

            if expanded {
                if pages.weather {
                    NotchWeather(openWeather: openWeather)
                        .transition(.opacity)
                } else if let track = playback.track {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            artworkButton
                            TrackLabels(track: track, source: playback.player?.name, prominent: true)
                                .layoutPriority(1)
                            Spacer(minLength: 4)
                            Button(action: toggleFull) {
                                Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlayerButtonStyle())
                            .help(full ? "Smaller player" : "Larger player")
                            .accessibilityLabel(full ? "Smaller player" : "Larger player")
                        }
                        ProgressViewRow(playback: playback, seekable: true, inline: true)
                            .id((playback.player?.rawValue ?? "") + track.id)
                        PlaybackControls(playback: playback, prominent: true, showsButtonBackgrounds: false)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .leading) {
                                if let favorited = track.favorited {
                                    Button(action: playback.toggleFavorite) {
                                        Image(systemName: favorited ? "heart.fill" : "heart")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(favorited ? Color.pink : .white.opacity(0.85))
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlayerButtonStyle())
                                    .help(favorited ? "Remove Apple Music favorite" : "Favorite in Apple Music")
                                    .accessibilityLabel(favorited ? "Remove Apple Music favorite" : "Favorite in Apple Music")
                                }
                            }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 7)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 6) {
                        Text(playback.unavailable ? "Music access unavailable" : "Nothing playing")
                            .font(.headline)
                        Text(playback.unavailable
                             ? "Allow music access in System Settings → Privacy & Security → Automation."
                             : "Play something in Spotify or Apple Music.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    pageIndicator(weather: false, label: "Music")
                    pageIndicator(weather: true, label: "Weather")
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: pages.weather)
        .clipShape(shape)
        .background { surface(in: shape) }
        .overlay {
            shape.fill(.white)
                .opacity(hover.isHighlighted && !expanded ? 0.035 : 0)
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hover.isHighlighted)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: expanded)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }

    private func pageIndicator(weather: Bool, label: String) -> some View {
        let selected = pages.weather == weather
        return Button {
            pages.weather = weather
        } label: {
            Capsule()
                .fill(.white.opacity(selected ? 0.92 : 0.32))
                .frame(width: 4, height: 4)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) page")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var clockActivityRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if clockActivities.isEmpty {
                    Button(action: openClock) {
                        HStack(spacing: 9) {
                            Image(systemName: "timer")
                                .foregroundStyle(.orange)
                            Text("Timers & Stopwatch")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 39)
                        .background(.white.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .accessibilityHint("Opens Clock.")
                }
                ForEach(clockActivities) { activity in
                    Button(action: openClock) {
                        HStack(spacing: 8) {
                            clockSymbol(activity)
                                .frame(width: 27, height: 27)
                                .background(clockColor(for: activity).opacity(0.14), in: Circle())
                            Text(activity.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: 100)
                            clockTime(activity, size: 17)
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 13)
                        .frame(height: 39)
                        .background(.white.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .accessibilityHint(activity.isPaused ? "Paused. Opens Clock." : "Opens Clock.")
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.never)
        .frame(height: Self.clockRowHeight)
    }

    private func clockSymbol(_ activity: ClockActivity) -> some View {
        Image(systemName: activity.isPaused ? "pause.fill" : activity.kind.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(clockColor(for: activity))
            .accessibilityHidden(true)
    }

    private func clockTime(_ activity: ClockActivity, size: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: activity.isPaused ? 3600 : 0.25)) { context in
            Text(activity.displayTime(at: context.date))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(clockColor(for: activity))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func clockColor(for activity: ClockActivity) -> Color {
        activity.kind == .timer ? .orange : .mint
    }

    @ViewBuilder
    private func surface(in shape: NotchShape) -> some View {
        if glass && !reduceTransparency {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.45)), in: shape)
                    .allowsHitTesting(false)
            } else {
                shape.fill(.ultraThinMaterial).overlay { shape.fill(.black.opacity(0.38)) }
            }
            #else
            shape.fill(.ultraThinMaterial).overlay { shape.fill(.black.opacity(0.38)) }
            #endif
        } else {
            shape.fill(.black)
                .overlay {
                    if !reduceTransparency { glassRim(in: shape) }
                }
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func glassRim(in shape: NotchShape) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .mask { shape.stroke(lineWidth: 1.5) }
                .opacity(hover.isHighlighted ? 0.56 : 0.30)
        }
        #endif
    }

    private var artworkButton: some View {
        let label = "Open \(playback.player?.name ?? "music app")"
        return Button(action: openArtwork) {
            CoverView(playback: playback, size: full ? 74 : 46)
        }
        .buttonStyle(PlayerButtonStyle())
        .highPriorityGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { _ in dragArtwork(NSEvent.mouseLocation, false) }
            .onEnded { _ in dragArtwork(NSEvent.mouseLocation, true) })
        .help(playback.preview ? "Drag to the desktop" : "\(label) or drag to the desktop")
        .accessibilityLabel(label)
    }
}

final class LockArtwork: ObservableObject {
    enum Mode: CaseIterable {
        case record, cover, lyrics

        var next: Mode {
            switch self {
            case .record: .cover
            case .cover: .lyrics
            case .lyrics: .record
            }
        }

        var label: String {
            switch self {
            case .record: "Show record"
            case .cover: "Show album cover"
            case .lyrics: "Show lyrics"
            }
        }
    }

    @Published var mode: Mode = .record
}

struct LockCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playback: Playback
    let preview: Bool
    let artSize: CGFloat
    @ObservedObject var artwork: LockArtwork
    let modeChanged: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if preview {
                Text("Lock Screen Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let track = playback.track {
                HStack(spacing: 44) {
                    VStack(spacing: 12) {
                        artworkButton
                        controls(for: track)
                    }
                    .frame(width: artwork.mode == .lyrics ? artSize : 254)
                    if artwork.mode == .lyrics {
                        LockLyrics(playback: playback, track: track)
                            .id((playback.player?.rawValue ?? "") + track.id)

                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 34))
                    Text("Play a track to preview the lock screen player.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background { surface }
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if artwork.mode != .record, let image = playback.artwork {
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width * 0.72, height: geometry.size.height * 0.44)
                        .clipped()
                        .blur(radius: 44)
                        .opacity(0.38)
                        .mask { Ellipse().fill(RadialGradient(colors: [.white, .clear],
                                                             center: .center, startRadius: 16,
                                                             endRadius: geometry.size.height * 0.24)) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }

    private var artworkButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                artwork.mode = artwork.mode.next
            }
            modeChanged()
        } label: {
            if artwork.mode == .record {
                RecordView(playback: playback, size: artSize)
                    .transition(.opacity)
            } else {
                CoverView(playback: playback, size: artSize)
                    .overlay {
                        RoundedRectangle(cornerRadius: artSize * 0.16)
                            .strokeBorder(.white.opacity(0.22))
                    }
                    .transition(.opacity)
            }
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(artwork.mode.next.label)
        .help(artwork.mode.next.label)
    }

    private func controls(for track: Track) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                RecordView(playback: playback, size: 25)
                TrackLabels(track: track, source: playback.player?.name)
                Spacer(minLength: 4)
                if let player = playback.player {
                    Image(systemName: player == .music ? "music.note" : "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(player.name)
                }
            }
            ProgressViewRow(playback: playback, seekable: true)
                .id((playback.player?.rawValue ?? "") + track.id)
            PlaybackControls(playback: playback, showsButtonBackgrounds: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: 216)
        .background { surface }
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        return shape.fill(.ultraThinMaterial)
            .overlay { shape.fill(.black.opacity(0.27)) }
            .overlay { shape.strokeBorder(.white.opacity(0.17)) }
    }
}

private struct TrackLabels: View {
    let track: Track
    let source: String?
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.system(size: prominent ? 16 : 13, weight: .semibold))
            Text(track.artist.isEmpty ? (source ?? "") : track.artist)
                .font(.system(size: prominent ? 12 : 11))
                .foregroundStyle(.white.opacity(0.65))
        }
        .lineLimit(1)
    }
}

struct CoverView: View {
    @ObservedObject var playback: Playback
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork = playback.artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.indigo, .purple.opacity(0.5), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.42, weight: .semibold))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
        .accessibilityHidden(true)
    }
}

struct RecordView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playback: Playback
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || playback.track?.playing != true)) { _ in
            ZStack {
                Circle().fill(AngularGradient(colors: [
                    .black, Color(white: 0.27), .black, Color(white: 0.21), .black
                ], center: .center))
                ForEach(0..<12) { index in
                    Circle().strokeBorder(.white.opacity(0.13), lineWidth: 0.65)
                        .padding(size * (0.024 + CGFloat(index) * 0.025))
                }
                CoverView(playback: playback, size: size * 0.37).clipShape(Circle())
                Circle().fill(.black).frame(width: 6, height: 6)
            }
            .rotationEffect(.degrees(reduceMotion ? 0 : playback.position() * 120))
        }
        .frame(width: size, height: size)
        .overlay { Circle().strokeBorder(.white.opacity(0.18)) }
        .shadow(color: .black.opacity(0.32), radius: 9, y: 4)
        .accessibilityHidden(true)
    }
}

private struct Equalizer: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 16, paused: !playing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { index in
                    Capsule()
                        .fill(Color(red: 0.74, green: 0.67, blue: 1))
                        .frame(width: 2, height: playing ? 4 + 9 * abs(sin(time * 7 + Double(index))) : 3)
                }
            }
            .frame(width: 18, height: 18)
        }
        .accessibilityHidden(true)
    }
}

private struct PlayerButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct PlaybackControls: View {
    @ObservedObject var playback: Playback
    var prominent = false
    var showsButtonBackgrounds = true

    var body: some View {
        HStack(spacing: prominent ? 19 : 3) {
            control(.previous, "backward.fill", "Previous track")
            let playing = playback.track?.playing == true
            control(.toggle, playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play")
            control(.next, "forward.fill", "Next track")
        }
        .fixedSize()
    }

    private func control(_ command: PlaybackCommand, _ icon: String, _ label: String) -> some View {
        Button { playback.send(command) } label: {
            Image(systemName: icon)
                .font(.system(size: prominent ? (command == .toggle ? 23 : 16) : (command == .toggle ? 15 : 11),
                              weight: .semibold))
                .frame(width: prominent ? 44 : 26, height: prominent ? 35 : 28)
                .background {
                    if showsButtonBackgrounds {
                        RoundedRectangle(cornerRadius: prominent ? 12 : 8)
                            .fill(.white.opacity(command == .toggle ? 0.16 : 0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private final class ScrubState: ObservableObject {
    @Published var position: Double?
}

private struct ProgressViewRow: View {
    @ObservedObject var playback: Playback
    var seekable = false
    var inline = false
    @StateObject private var scrub = ScrubState()

    var body: some View {
        if let track = playback.track, track.duration.isFinite, track.duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let position = scrub.position ?? playback.position()
                if inline {
                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            Text(time(position)).frame(minWidth: 27, alignment: .leading)
                            inlineScrubber(position: position, duration: track.duration)
                            Text(time(track.duration)).frame(minWidth: 27, alignment: .trailing)
                        }
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.62))
                        if let error = playback.controlError {
                            Text(error).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                } else {
                    VStack(spacing: seekable ? 2 : 5) {
                        if seekable {
                            Slider(value: Binding(
                                get: { scrub.position ?? playback.position() },
                                set: { value in
                                    if scrub.position != nil { scrub.position = value }
                                    else { playback.seek(to: value) }
                                }
                            ), in: 0...track.duration) {
                                Text("Playback position")
                            } onEditingChanged: { editing in
                                if editing {
                                    scrub.position = playback.position()
                                } else if let target = scrub.position {
                                    scrub.position = nil
                                    playback.seek(to: target)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(.white)
                        } else {
                            ProgressView(value: position, total: track.duration)
                                .progressViewStyle(.linear)
                                .tint(Color(red: 0.74, green: 0.67, blue: 1))
                                .accessibilityLabel("Playback progress")
                        }
                        HStack {
                            Text(time(position))
                            Spacer()
                            if seekable, let error = playback.controlError {
                                Text(error).foregroundStyle(.orange)
                                Spacer()
                            }
                            Text(time(track.duration))
                        }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                    }
                }
            }
        }
    }

    private func inlineScrubber(position: Double, duration: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = position.isFinite ? min(max(position / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.20))
                Capsule()
                    .fill(.white.opacity(scrub.position == nil ? 0.74 : 1))
                    .frame(width: width * fraction)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard width > 0 else { return }
                    scrub.position = min(max(drag.location.x / width, 0), 1) * duration
                }
                .onEnded { drag in
                    scrub.position = nil
                    guard width > 0 else { return }
                    playback.seek(to: min(max(drag.location.x / width, 0), 1) * duration)
                })
        }
        .frame(height: 17)
        .accessibilityLabel("Playback position")
        .accessibilityValue(time(position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.seek(to: min(position + 5, duration))
            case .decrement: playback.seek(to: max(position - 5, 0))
            @unknown default: break
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, let whole = Int(exactly: seconds.rounded(.down)) else { return "–:––" }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
