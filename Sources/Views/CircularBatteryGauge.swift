import SwiftUI

/// A circular battery gauge: a track ring with a coloured progress arc and the
/// percentage + side label centred inside.
struct CircularBatteryGauge: View {
    let level: Int
    let label: LocalizedStringKey
    var present: Bool = true
    var diameter: CGFloat = 74

    private var fraction: Double { present ? Double(max(0, min(100, level))) / 100 : 0 }

    private var color: Color {
        guard present else { return .secondary.opacity(0.4) }
        switch level {
        case 0..<15: return .red
        case 15..<30: return .orange
        default: return .green
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: diameter * 0.08)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: diameter * 0.08, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(present ? "\(level)%" : "—")
                    .font(.system(size: diameter * 0.21, weight: .semibold, design: .rounded))
                Text(label)
                    .font(.system(size: diameter * 0.14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
