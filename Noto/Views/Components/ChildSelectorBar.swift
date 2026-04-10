import SwiftUI
import TipKit

struct ChildSelectorTip: Tip {
    var title: Text { Text("Sélecteur d'enfant") }
    var message: Text? { Text("Sélectionnez un enfant pour filtrer toute l'app, ou laissez sur « Tous ».") }
    var image: Image? { Image(systemName: "hand.tap") }
}

struct ChildSelectorBar: View {
    let children: [Child]
    @Binding var selectedChild: Child?
    var onAddChild: (() -> Void)?

    @State private var selectorTip = ChildSelectorTip()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Text("Afficher :")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)

                // "Tous" = nil selection (aggregated view)
                SelectorChip(
                    label: "Tous",
                    isSelected: selectedChild == nil,
                    action: { selectedChild = nil }
                )

                ForEach(children) { child in
                    SelectorChip(
                        label: child.firstName,
                        isSelected: selectedChild?.id == child.id,
                        hasAlert: childHasAlert(child),
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
        .popoverTip(selectorTip)
        .background(NotoTheme.Colors.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NotoTheme.Colors.border)
                .frame(height: 0.5)
        }
    }

    private func childHasAlert(_ child: Child) -> Bool {
        let now = Date.now
        let in24h = now.addingTimeInterval(86_400)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
        let urgentHomework = child.homework.contains { !$0.done && $0.dueDate <= in24h }
        let recentLowGrade = child.grades.contains {
            $0.date >= sevenDaysAgo && $0.normalizedValue < 10
        }
        return urgentHomework || recentLowGrade
    }
}

// MARK: - Chip

private struct SelectorChip: View {
    let label: String
    let isSelected: Bool
    var hasAlert: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(NotoTheme.Typography.caption)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm)
                .background(isSelected ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                .foregroundStyle(isSelected ? NotoTheme.Colors.shadow : NotoTheme.Colors.textPrimary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : NotoTheme.Colors.border, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if hasAlert {
                        Circle()
                            .fill(NotoTheme.Colors.danger)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
