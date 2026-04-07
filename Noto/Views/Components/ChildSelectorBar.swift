import SwiftUI

struct ChildSelectorBar: View {
    let children: [Child]
    @Binding var selectedChild: Child?
    var onAddChild: (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                // "Famille" = nil selection (aggregated view)
                SelectorChip(
                    label: "Famille",
                    isSelected: selectedChild == nil,
                    action: { selectedChild = nil }
                )

                ForEach(children) { child in
                    SelectorChip(
                        label: child.firstName,
                        isSelected: selectedChild?.id == child.id,
                        action: { selectedChild = child }
                    )
                }

                // Add child button
                if let onAddChild {
                    Button(action: onAddChild) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().stroke(NotoTheme.Colors.textSecondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Chip

private struct SelectorChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(NotoTheme.Typography.caption)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm)
                .background(isSelected ? NotoTheme.Colors.brand : Color.clear)
                .foregroundStyle(isSelected ? .white : NotoTheme.Colors.textSecondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : NotoTheme.Colors.textSecondary.opacity(0.3))
                )
        }
        .buttonStyle(.plain)
    }
}
