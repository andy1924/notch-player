import AppKit
import SwiftUI

enum DesktopStyle: String, CaseIterable {
    case turntable, sleeve, aura

    var title: String { rawValue.capitalized }
}

struct DesktopPlayer: View {
    @ObservedObject var playback: Playback
    let style: DesktopStyle

    private static let fallbackTint = Color(red: 0.52, green: 0.27, blue: 0.80)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 460, geometry.size.height / 315)
            ZStack {
                switch style {
                case .turntable: turntable
                case .sleeve: sleeve
                case .aura: aura
                }
            }
            .frame(width: 460, height: 315)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var turntable: some View {
        ZStack(alignment: .leading) {
            CoverView(playback: playback, size: 175)
                .rotationEffect(.degrees(-7))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 12)
                .offset(x: 23, y: 5)

            ZStack(alignment: .topLeading) {
                let deck = RoundedRectangle(cornerRadius: 13)
                deck.fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.075)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                deck.strokeBorder(.white.opacity(0.15))
                Circle().fill(.gray.gradient)
                    .frame(width: 224, height: 224)
                    .offset(x: 16, y: 15)
                RecordView(playback: playback, size: 215)
                    .offset(x: 20.5, y: 19.5)
                Circle().fill(.gray.gradient)
                    .frame(width: 27, height: 27)
                    .offset(x: 255, y: 30)
                Capsule().fill(.white.gradient)
                    .frame(width: 5, height: 146)
                    .rotationEffect(.degrees(playback.track?.playing == true ? 27 : 4), anchor: .top)
                    .offset(x: 266, y: 41)
                    .animation(.easeInOut(duration: 0.25), value: playback.track?.playing)
                Circle().fill(playback.track?.playing == true ? .red : .gray)
                    .frame(width: 7, height: 7)
                    .offset(x: 19, y: 237)
                Capsule().fill(.gray.gradient)
                    .frame(width: 24, height: 7)
                    .offset(x: 34, y: 237)
            }
            .frame(width: 300, height: 258)
            .shadow(color: .black.opacity(0.55), radius: 18, y: 11)
            .offset(x: 136)
        }
        .frame(width: 460, height: 315, alignment: .leading)
    }

    private var sleeve: some View {
        ZStack {
            RecordView(playback: playback, size: 209)
                .offset(x: 76)
            CoverView(playback: playback, size: 225)
                .rotationEffect(.degrees(-5))
                .shadow(color: .black.opacity(0.56), radius: 17, y: 12)
                .offset(x: -54, y: 4)
        }
    }

    private var aura: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 48)
                .fill(Self.fallbackTint)
                .frame(width: 230, height: 174)
                .blur(radius: 38)
                .overlay {
                    if let artwork = playback.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 268, height: 200)
                            .clipped()
                            .saturation(1.65)
                            .blur(radius: 36)
                    }
                }
            CoverView(playback: playback, size: 192)
                .shadow(color: .black.opacity(0.42), radius: 14, y: 9)
        }
    }
}
