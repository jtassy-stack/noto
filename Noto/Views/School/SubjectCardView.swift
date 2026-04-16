import SwiftUI

/// Per-subject card following the nōto visual grammar.
/// Shows subject name (N1 serif), average + trend (N2 data),
/// homework context (N3 metadata), and optional culture link.
struct SubjectCardView: View {
    let subject: String
    let grades: [Grade]
    let insight: Insight?
    let pendingHomework: [Homework]
    let cultureHint: String?

    private var average: Double? {
        guard !grades.isEmpty else { return nil }
        let weighted = grades.map { $0.normalizedValue * $0.coefficient }
        let totalCoeff = grades.map(\.coefficient).reduce(0, +)
        guard totalCoeff > 0 else { return nil }
        return weighted.reduce(0, +) / totalCoeff
    }

    private var trendInfo: (label: String, color: Color)? {
        guard let insight else { return nil }
        if insight.type == .difficulty {
            return ("↓ difficulté", NotoTheme.Colors.danger)
        }
        if insight.type == .strength {
            return ("↑ point fort", NotoTheme.Colors.success)
        }
        if insight.type == .trend {
            let val = insight.value
            if val.contains("hausse") || val.contains("improving") || val.contains("↑") {
                return ("↑", NotoTheme.Colors.success)
            }
            if val.contains("baisse") || val.contains("declining") || val.contains("↓") {
                return ("↓", NotoTheme.Colors.danger)
            }
            return ("→ stable", NotoTheme.Colors.textSecondary)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            // Row 1: Subject name + average + trend
            HStack(alignment: .center, spacing: NotoTheme.Spacing.sm) {
                // N1 — Subject name (serif, human register)
                Text(subject)
                    .font(NotoTheme.Typography.subjectName)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                Spacer()

                // N2 — Average (functional, data)
                if let avg = average {
                    Text(String(format: "%.1f", avg))
                        .font(NotoTheme.Typography.data)
                        .foregroundStyle(NotoTheme.Colors.brand)
                }

                // Trend indicator
                if let trend = trendInfo {
                    Text(trend.label)
                        .font(NotoTheme.Typography.functional(12, weight: .medium))
                        .foregroundStyle(trend.color)
                }
            }

            // Row 2: N3 metadata — homework or context
            if let hw = pendingHomework.first {
                Text("\(hw.descriptionText) · \(homeworkDateLabel(hw.dueDate))")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.65)
                    .lineLimit(1)
            }

            // Row 3: Culture link (if available)
            if let hint = cultureHint {
                Text("🧭 \(hint)")
                    .font(NotoTheme.Typography.functional(12, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.info)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .notoCard()
    }

    private func homeworkDateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "aujourd'hui" }
        if Calendar.current.isDateInTomorrow(date) { return "demain" }
        return "pour le \(date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))"
    }
}
