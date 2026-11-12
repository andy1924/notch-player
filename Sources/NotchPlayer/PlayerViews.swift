import SwiftUI

struct NotchShape: Shape {
    let floating: Bool
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(21 + 9 * expansion, rect.height * 0.5)
        if floating { return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect) }
        let shoulder = 6 + 6 * expansion
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

struct NotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playback: Playback
    let topHeight: CGFloat
    let floating: Bool
    let expanded: Bool
    @ObservedObject var hover: NotchHover
    let toggle: () -> Void

    var body: some View {
        let shape = NotchShape(floating: floating, expansion: expanded ? 1 : 0)
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack {
                    if expanded {
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
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
                .transition(.identity)
                .padding(.horizontal, expanded ? 20 : 11)
                .frame(maxWidth: .infinity)
                .frame(height: topHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse notch player" : "Expand notch player")

            if expanded {
                if let track = playback.track {
                    VStack(spacing: 7) {
                        HStack(spacing: 12) {
                            artworkButton
                            TrackLabels(track: track, source: playback.player?.name)
                            Spacer(minLength: 4)
                        }
                        ProgressViewRow(playback: playback, seekable: true)
                            .id((playback.player?.rawValue ?? "") + track.id)
                        PlaybackControls(playback: playback, prominent: true)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 3)
                    .padding(.bottom, 13)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            shape.fill(.black)
                .overlay {
                    shape.fill(.white)
                        .opacity(hover.isHighlighted && !expanded ? 0.09 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hover.isHighlighted)
                }
        }
        .clipShape(shape)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: expanded)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }

    private var artworkButton: some View {
        let label = "Open \(playback.player?.name ?? "music app")"
        return Button(action: playback.openPlayer) {
            CoverView(playback: playback, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(4)
                        .background(.black.opacity(0.65), in: UnevenRoundedRectangle(topLeadingRadius: 6))
                }
        }
        .buttonStyle(PlayerButtonStyle())
        .disabled(playback.preview)
        .help(label)
        .accessibilityLabel(label)
    }
}

final class LockArtwork: ObservableObject {
    @Published var showCover = false
}

struct LockCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playback: Playback
    let preview: Bool
    let artSize: CGFloat
    @ObservedObject var artwork: LockArtwork

    var body: some View {
        VStack(spacing: 10) {
            if preview {
                Text("Lock Screen Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let track = playback.track {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        artwork.showCover.toggle()
                    }
                } label: {
                    if artwork.showCover {
                        CoverView(playback: playback, size: artSize)
                            .transition(.opacity)
                    } else {
                        RecordView(playback: playback, size: artSize)
                            .transition(.opacity)
                    }
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel(artwork.showCover ? "Show record" : "Show album cover")

                VStack(spacing: 5) {
                    HStack(spacing: 10) {
                        TrackLabels(track: track, source: playback.player?.name, prominent: true)
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
                    PlaybackControls(playback: playback, prominent: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background { surface }
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
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
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
            Text(track.title).font(.system(size: prominent ? 15 : 13, weight: .semibold))
            Text(track.artist.isEmpty ? (source ?? "") : track.artist)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
        }
        .lineLimit(1)
    }
}

private struct CoverView: View {
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

private struct RecordView: View {
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
                .font(.system(size: prominent ? (command == .toggle ? 20 : 14) : (command == .toggle ? 15 : 11),
                              weight: .semibold))
                .frame(width: prominent ? 44 : 26, height: prominent ? 35 : 28)
                .background(.white.opacity(command == .toggle ? 0.16 : 0.08),
                            in: RoundedRectangle(cornerRadius: prominent ? 12 : 8))
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
    @StateObject private var scrub = ScrubState()

    var body: some View {
        if let track = playback.track, track.duration.isFinite, track.duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let position = scrub.position ?? playback.position()
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

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, let whole = Int(exactly: seconds.rounded(.down)) else { return "–:––" }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
