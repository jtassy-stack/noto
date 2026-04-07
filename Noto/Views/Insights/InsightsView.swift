import SwiftUI
import SwiftData

struct InsightsView: View {
    let selectedChild: Child?

    @Query private var families: [Family]

    private var children: [Child] {
        if let child = selectedChild { return [child] }
        return families.first?.children ?? []
    }

    private var allInsights: [(child: Child, insight: Insight)] {
        children.flatMap { child in
            child.insights.map { (child: child, insight: $0) }
        }.sorted { $0.insight.detectedAt > $1.insight.detectedAt }
    }

    private var subjectAverages: [(subject: String, average: Double, count: Int)] {
        var bySubject: [String: [Double]] = [:]
        for child in children {
            for grade in child.grades {
                bySubject[grade.subject, default: []].append(grade.normalizedValue)
            }
        }
        return bySubject.map { (subject: $0.key, average: $0.value.reduce(0, +) / Double($0.value.count), count: $0.value.count) }
            .sorted { $0.average > $1.average }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: NotoTheme.Spacing.md) {
                    if !subjectAverages.isEmpty {
                        // Subject averages
                        SectionHeader(title: "Moyennes par matière")

                        ForEach(subjectAverages, id: \.subject) { item in
                            SubjectAverageRow(subject: item.subject, average: item.average, count: item.count)
                        }
                    }

                    if !allInsights.isEmpty {
                        SectionHeader(title: "Tendances détectées")

                        ForEach(allInsights, id: \.insight.id) { item in
                            InsightRow(
                                insight: item.insight,
                                showChild: children.count > 1,
                                childName: item.child.firstName
                            )
                        }
                    }

                    if subjectAverages.isEmpty && allInsights.isEmpty {
                        ContentUnavailableView(
                            "Suivi",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Les tendances et insights apparaîtront après synchronisation des notes.")
                        )
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
            .navigationTitle("Suivi")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(NotoTheme.Typography.caption)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, NotoTheme.Spacing.sm)
    }
}

// MARK: - Subject Average

private struct SubjectAverageRow: View {
    let subject: String
    let average: Double
    let count: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                Text(subject)
                    .font(NotoTheme.Typography.headline)
                Text("\(count) note\(count > 1 ? "s" : "")")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            Spacer()

            // Average bar
            Text(String(format: "%.1f", average))
                .font(NotoTheme.Typography.data)
                .foregroundStyle(averageColor)
            Text("/20")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(NotoTheme.Spacing.md)
        .background(averageColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
    }

    private var averageColor: Color {
        if average >= 14 { return NotoTheme.Colors.success }
        if average >= 10 { return NotoTheme.Colors.textPrimary }
        if average >= 8 { return NotoTheme.Colors.warning }
        return NotoTheme.Colors.danger
    }
}

// MARK: - Insight Row

private struct InsightRow: View {
    let insight: Insight
    let showChild: Bool
    let childName: String

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                if showChild {
                    Text(childName)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(insight.subject)
                    .font(NotoTheme.Typography.headline)
                Text(insight.value)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(NotoTheme.Spacing.md)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
    }

    private var iconName: String {
        switch insight.type {
        case .difficulty: "exclamationmark.triangle"
        case .strength: "star.fill"
        case .trend: "chart.line.uptrend.xyaxis"
        case .alert: "bell.badge"
        }
    }

    private var iconColor: Color {
        switch insight.type {
        case .difficulty: NotoTheme.Colors.danger
        case .strength: NotoTheme.Colors.success
        case .trend: NotoTheme.Colors.brand
        case .alert: NotoTheme.Colors.warning
        }
    }
}
