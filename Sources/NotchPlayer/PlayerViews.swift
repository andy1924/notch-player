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
                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            CoverView(playback: playback, size: 50)
                            TrackLabels(track: track, source: playback.player?.name)
                            Spacer(minLength: 4)
                            PlaybackControls(playback: playback)
                        }
                        ProgressViewRow(playback: playback)
                    }
                    .padding(.horizontal, 19)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
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
}

final class LockArtwork: ObservableObject {
    @Published var showCover = false
}

struct LockCard: View {
    @ObservedObject var playback: Playback
    let preview: Bool
    @ObservedObject var artwork: LockArtwork

    var body: some View {
        VStack(spacing: 12) {
            if preview {
                Text("LOCK SCREEN PREVIEW")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            if let track = playback.track {
                HStack(spacing: 18) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { artwork.showCover.toggle() }
                    } label: {
                        if artwork.showCover {
                            CoverView(playback: playback, size: 84)
                        } else {
                            RecordView(playback: playback)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(artwork.showCover ? "Show record" : "Show album cover")

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TrackLabels(track: track, source: playback.player?.name)
                            Spacer(minLength: 2)
                            PlaybackControls(playback: playback)
                        }
                        ProgressViewRow(playback: playback)
                    }
                }
            } else {
                Image(systemName: "record.circle")
                    .font(.system(size: 34))
                Text("Play a track to preview the lock screen player.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.16))
                }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }
}

private struct TrackLabels: View {
    let track: Track
    let source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.system(size: 13, weight: .semibold))
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
    @ObservedObject var playback: Playback

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: playback.track?.playing != true)) { _ in
            ZStack {
                Circle().fill(AngularGradient(colors: [
                    .black, Color(white: 0.27), .black, Color(white: 0.21), .black
                ], center: .center))
                ForEach(0..<8) { index in
                    Circle().strokeBorder(.white.opacity(0.11), lineWidth: 0.6)
                        .padding(CGFloat(index) * 3 + 2)
                }
                CoverView(playback: playback, size: 31).clipShape(Circle())
                Circle().fill(.black).frame(width: 4, height: 4)
            }
            .rotationEffect(.degrees(playback.position() * 120))
        }
        .frame(width: 84, height: 84)
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

private struct PlaybackControls: View {
    @ObservedObject var playback: Playback

    var body: some View {
        HStack(spacing: 3) {
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
                .font(.system(size: command == .toggle ? 15 : 11, weight: .semibold))
                .frame(width: 26, height: 28)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ProgressViewRow: View {
    @ObservedObject var playback: Playback

    var body: some View {
        if let track = playback.track, track.duration.isFinite, track.duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let position = playback.position()
                VStack(spacing: 5) {
                    ProgressView(value: position, total: track.duration)
                        .progressViewStyle(.linear)
                        .tint(Color(red: 0.74, green: 0.67, blue: 1))
                        .accessibilityLabel("Playback progress")
                    HStack {
                        Text(time(position))
                        Spacer()
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
