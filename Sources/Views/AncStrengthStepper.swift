import SwiftUI

/// ANC strength picker: minus and plus around a row of steps, mirroring the
/// control the Galaxy Wearable app shows. Buds3/4 Pro expose five steps; other
/// models only distinguish two, and the same control covers both.
struct AncStrengthStepper: View {
    let level: Int
    let count: Int
    var tint: Color = .blue
    let onChange: (Int) -> Void

    private var clamped: Int { max(0, min(count - 1, level)) }

    var body: some View {
        HStack(spacing: 8) {
            stepButton("minus", enabled: clamped > 0) { onChange(clamped - 1) }
            track
            stepButton("plus", enabled: clamped < count - 1) { onChange(clamped + 1) }
        }
        // One adjustable element rather than a row of unlabelled circles, which
        // VoiceOver otherwise reads as a handful of anonymous buttons. Reusing
        // the existing "ANC strength" key keeps this out of the 11 catalogues.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("ANC strength"))
        .accessibilityValue(Text(verbatim: "\(clamped + 1)/\(count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if clamped < count - 1 { onChange(clamped + 1) }
            case .decrement: if clamped > 0 { onChange(clamped - 1) }
            @unknown default: break
            }
        }
    }

    private var track: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 4)
                .padding(.horizontal, 9)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { step in
                    Button { onChange(step) } label: {
                        ZStack {
                            if step == clamped {
                                Circle()
                                    .fill(Color(nsColor: .windowBackgroundColor))
                                    .frame(width: 18, height: 18)
                                Circle()
                                    .strokeBorder(tint, lineWidth: 2.5)
                                    .frame(width: 18, height: 18)
                            } else {
                                Circle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 20)
    }

    private func stepButton(
        _ symbol: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.35))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
