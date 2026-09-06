import SwiftUI

/// Listen-mode picker: circles strung along a rail, the way Galaxy Wearable
/// draws it.
///
/// Shared by the menu-bar panel and the dashboard. The two had grown separate
/// copies that had already drifted — different circle sizes, different fills for
/// the unselected state, and labels laid out two different ways — so the same
/// control looked like two controls depending on where you opened it.
struct ListenModePicker: View {
    let modes: [NoiseControlMode]
    let selection: NoiseControlMode
    var tint: Color = .blue
    var circleSize: CGFloat = 36
    let onSelect: (NoiseControlMode) -> Void

    var body: some View {
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(max(1, modes.count))
            ZStack(alignment: .top) {
                // The rail stops at the outer circles' centres rather than
                // running the full width, so it reads as strung between them.
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: max(0, geo.size.width - cell), height: 2)
                    .position(x: geo.size.width / 2, y: circleSize / 2)
                HStack(spacing: 0) {
                    ForEach(modes) { mode in
                        button(mode).frame(width: cell)
                    }
                }
            }
        }
        .frame(height: circleSize + 32)
    }

    private func button(_ mode: NoiseControlMode) -> some View {
        let selected = mode == selection
        return Button { onSelect(mode) } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(selected ? tint : Color.secondary.opacity(0.14))
                        .frame(width: circleSize, height: circleSize)
                    Image(systemName: mode.iconName)
                        .font(.system(size: circleSize * 0.42, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                Text(LocalizedStringKey(mode.shortName))
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? tint : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(mode.shortName)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
