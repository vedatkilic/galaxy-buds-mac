import SwiftUI

/// A battery gauge drawn as an open 270° dial rather than a closed ring: the
/// gap at the bottom gives the sweep a start and an end, so "nearly full" and
/// "full" read differently at a glance where two closed circles do not.
struct CircularBatteryGauge: View {
    let level: Int
    let label: LocalizedStringKey
    var present: Bool = true
    var charging: Bool = false
    var diameter: CGFloat = 74

    /// Fraction of a full turn the dial sweeps — 0.75 leaves a 90° gap.
    private static let sweep: CGFloat = 0.75
    /// Puts the sweep's start at the lower left, centring the gap on the bottom.
    private static let startAngle: Double = 135

    private var fraction: CGFloat { present ? CGFloat(max(0, min(100, level))) / 100 : 0 }

    private var lineWidth: CGFloat { diameter * 0.085 }

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
            arc(to: Self.sweep)
                .stroke(Color.secondary.opacity(0.18),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(to: Self.sweep * fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            VStack(spacing: 0) {
                Text(present ? "\(level)%" : "—")
                    .font(.system(size: diameter * 0.215, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: diameter * 0.145))
                    .foregroundStyle(.secondary)
            }
            .frame(width: diameter * 0.7)
            // Nudged up so the pair sits centred in the ink of the dial rather
            // than in its bounding box, which the bottom gap skews.
            .offset(y: -diameter * 0.06)

            // The bolt lives in the gap at the bottom of the dial. Inline with
            // the percentage it pushed "100%" wider than the arc it sits in.
            if present && charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: diameter * 0.17))
                    .foregroundStyle(.green)
                    .offset(y: diameter * 0.33)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }

    /// A `Circle` trimmed to `end` of a turn and rotated so the sweep begins at
    /// the lower left. `trim(to: 0)` draws nothing, which is what an absent
    /// reading should look like.
    private func arc(to end: CGFloat) -> some Shape {
        Circle()
            .trim(from: 0, to: end)
            .rotation(.degrees(Self.startAngle))
    }
}
