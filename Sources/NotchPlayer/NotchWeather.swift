import SwiftUI

struct NotchWeather: View {
    let openWeather: () -> Void

    var body: some View {
        Button(action: openWeather) {
            HStack(spacing: 12) {
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 25, weight: .medium))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weather").font(.system(size: 14, weight: .semibold))
                    Text("Hourly forecast in macOS Weather")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Weather")
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
    }
}
