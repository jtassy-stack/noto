import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    let selectedChild: Child?

    @Query private var families: [Family]
    @State private var selectedSubject: String? = nil
    @State private var showTrendSheet: Insight? = nil

    var onNavigateToHomework: (() -> Void)? = nil
    var onNavigateToDiscover: ((_ subject: String) -> Void)? = nil

    private var children: [Child] {
        if let child = selectedChild { return [child] }
        return families.first?.children ?? []
    }

    private var allGrades: [Grade] {
        children.flatMap(\.grades).sorted { $0.date < $1.date }
    }

    private var allInsights: [(child: Child, insight: Insight)] {
        children.flatMap { child in
            child.insights.map { (child: child, insight: $0) }
        }.sorted { $0.insight.detectedAt > $1.insight.detectedAt }
    }

    /// Weighted general average across all grades
    private var generalAverage: Double? {
        let grades = allGrades
        guard !grades.isEmpty else { return nil }
        let totalWeight = grades.reduce(0.0) { $0 + $1.coefficient }
        guard totalWeight > 0 else { return nil }
        return grades.reduce(0.0) { $0 + $1.normalizedValue * $1.coefficient } / totalWeight
    }

    /// Per-subject weighted averages + class average
    private var subjectAverages: [(subject: String, average: Double, classAverage: Double?, count: Int, trend: Double?)] {
        var bySubject: [String: [Grade]] = [:]
        for grade in allGrades {
            bySubject[grade.subject, default: []].append(grade)
        }
        return bySubject.map { subject, grades in
            let totalWeight = grades.reduce(0.0) { $0 + $1.coefficient }
            let avg = totalWeight > 0
                ? grades.reduce(0.0) { $0 + $1.normalizedValue * $1.coefficient } / totalWeight
                : grades.map(\.normalizedValue).reduce(0, +) / Double(grades.count)
            let classAvgs = grades.compactMap(\.classAverage)
            let classAvg: Double? = classAvgs.isEmpty ? nil : classAvgs.reduce(0, +) / Double(classAvgs.count)
            let sorted = grades.sorted { $0.date < $1.date }
            let trend: Double? = sorted.count >= 2
                ? sorted.last!.normalizedValue - sorted[sorted.count - 2].normalizedValue
                : nil
            return (subject: subject, average: avg, classAverage: classAvg, count: grades.count, trend: trend)
        }
        .sorted { $0.average > $1.average }
    }

    /// Grades for the selected subject (or all) for the evolution chart
    private var chartGrades: [(date: Date, value: Double, subject: String)] {
        let grades = selectedSubject == nil
            ? allGrades
            : allGrades.filter { $0.subject == selectedSubject }
        return grades.map { (date: $0.date, value: $0.normalizedValue, subject: $0.subject) }
    }

    /// True when all children are ENT (no grades)
    private var isENTOnly: Bool {
        children.allSatisfy { $0.schoolType == .ent }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: NotoTheme.Spacing.lg) {
                    if isENTOnly {
                        entInsightsContent
                    } else if allGrades.isEmpty {
                        ContentUnavailableView(
                            "Suivi",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Les graphiques apparaîtront après synchronisation des notes.")
                        )
                    } else {
                        generalAverageCard
                        evolutionChartCard
                        subjectAveragesCard
                        if !allInsights.isEmpty { insightsSection }
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Suivi")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $showTrendSheet) { insight in
                TrendDetailSheet(insight: insight, grades: allGrades.filter { $0.subject == insight.subject })
            }
        }
    }

    // MARK: - ENT Insights (no grades — homework + messages + schoolbook)

    @ViewBuilder
    private var entInsightsContent: some View {
        let allHomework = children.flatMap(\.homework)
        let allMessages = children.flatMap(\.messages)
        let schoolbookWords = allMessages.filter { $0.kind == .schoolbook }
        let conversations = allMessages.filter { $0.kind == .conversation }
        let doneCount = allHomework.filter(\.done).count
        let totalHW = allHomework.count
        let unreadCount = conversations.filter { !$0.read }.count
        let unsignedCount = schoolbookWords.filter { !$0.read }.count

        // Stats tiles
        HStack(spacing: NotoTheme.Spacing.md) {
            ENTStatTile(
                value: totalHW > 0 ? "\(doneCount)/\(totalHW)" : "—",
                label: "Devoirs faits",
                icon: "checkmark.circle",
                color: doneCount == totalHW ? NotoTheme.Colors.brand : NotoTheme.Colors.amber
            )
            ENTStatTile(
                value: "\(unreadCount)",
                label: "Non lus",
                icon: "envelope.badge",
                color: unreadCount > 0 ? NotoTheme.Colors.cobalt : NotoTheme.Colors.mist
            )
            ENTStatTile(
                value: "\(unsignedCount)",
                label: "À signer",
                icon: "text.book.closed",
                color: unsignedCount > 0 ? NotoTheme.Colors.amber : NotoTheme.Colors.mist
            )
        }

        // Recent schoolbook timeline
        if !schoolbookWords.isEmpty {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                Text("Carnet de liaison")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                ForEach(schoolbookWords.sorted(by: { $0.date > $1.date }).prefix(5), id: \.id) { word in
                    HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
                        Circle()
                            .fill(word.read ? NotoTheme.Colors.brand : NotoTheme.Colors.amber)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.subject)
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text("\(word.sender) · \(word.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(NotoTheme.Spacing.lg)
            .notoCard()
        }

        // Recent messages
        if !conversations.isEmpty {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                Text("Messages récents")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                ForEach(conversations.sorted(by: { $0.date > $1.date }).prefix(5), id: \.id) { msg in
                    HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
                        Circle()
                            .fill(msg.read ? Color.clear : NotoTheme.Colors.cobalt)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(msg.sender)
                                .font(NotoTheme.Typography.body)
                                .fontWeight(msg.read ? .regular : .bold)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text(msg.subject)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(msg.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                            .font(NotoTheme.Typography.dataSmall)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
            }
            .padding(NotoTheme.Spacing.lg)
            .notoCard()
        }

        if allHomework.isEmpty && allMessages.isEmpty {
            ContentUnavailableView(
                "Suivi",
                systemImage: "chart.xyaxis.line",
                description: Text("Les données de suivi apparaîtront après synchronisation.")
            )
        }
    }

    // MARK: - General Average Card

    private var generalAverageCard: some View {
        HStack(spacing: NotoTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                Text("Moyenne générale")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                if let avg = generalAverage {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", avg))
                            .font(NotoTheme.Typography.mono(48, weight: .bold))
                            .foregroundStyle(averageColor(avg))
                        Text("/20")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    Text(averageLabel(avg))
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(averageColor(avg))
                }
            }

            Spacer()

            // Mini ring gauge
            if let avg = generalAverage {
                ZStack {
                    Circle()
                        .stroke(averageColor(avg).opacity(0.15), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: avg / 20)
                        .stroke(averageColor(avg), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.8), value: avg)
                    Text("\(Int(avg * 5))%")
                        .font(NotoTheme.Typography.mono(12, weight: .bold))
                        .foregroundStyle(averageColor(avg))
                }
                .frame(width: 72, height: 72)
            }
        }
        .padding(NotoTheme.Spacing.lg)
        .notoCard()
    }

    // MARK: - Evolution Chart

    private var evolutionChartCard: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
            HStack {
                Text("Évolution")
                    .font(NotoTheme.Typography.headline)
                Spacer()
                // Subject filter pill
                Menu {
                    Button("Toutes les matières") { selectedSubject = nil }
                    Divider()
                    ForEach(subjectAverages, id: \.subject) { item in
                        Button(item.subject) { selectedSubject = item.subject }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedSubject ?? "Toutes")
                            .font(NotoTheme.Typography.caption)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NotoTheme.Colors.brand.opacity(0.1))
                    .foregroundStyle(NotoTheme.Colors.brand)
                    .clipShape(Capsule())
                }
            }

            if chartGrades.isEmpty {
                Text("Pas de notes pour cette matière")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 180)
            } else {
                Chart {
                    // Mean reference line
                    if let avg = selectedSubject == nil
                        ? generalAverage
                        : subjectAverages.first(where: { $0.subject == selectedSubject })?.average {
                        RuleMark(y: .value("Moyenne", avg))
                            .foregroundStyle(NotoTheme.Colors.brand.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .trailing, alignment: .center) {
                                Text(String(format: "%.1f", avg))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(NotoTheme.Colors.brand)
                            }
                    }

                    // 10/20 threshold
                    RuleMark(y: .value("Seuil", 10))
                        .foregroundStyle(NotoTheme.Colors.danger.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))

                    if selectedSubject != nil {
                        // Single subject: line + area + points + class average
                        let subjectGrades = (selectedSubject == nil ? allGrades : allGrades.filter { $0.subject == selectedSubject })
                            .sorted { $0.date < $1.date }

                        // Class average line (if available)
                        ForEach(subjectGrades, id: \.id) { grade in
                            if let ca = grade.classAverage {
                                LineMark(
                                    x: .value("Date", grade.date),
                                    y: .value("Classe", ca),
                                    series: .value("Série", "Classe")
                                )
                                .foregroundStyle(NotoTheme.Colors.mist.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .interpolationMethod(.catmullRom)
                            }
                        }

                        ForEach(chartGrades, id: \.date) { point in
                            AreaMark(
                                x: .value("Date", point.date),
                                y: .value("Note", point.value),
                                series: .value("Série", "Moi")
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [NotoTheme.Colors.brand.opacity(0.2), .clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Note", point.value),
                                series: .value("Série", "Moi")
                            )
                            .foregroundStyle(NotoTheme.Colors.brand)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2))

                            PointMark(
                                x: .value("Date", point.date),
                                y: .value("Note", point.value)
                            )
                            .foregroundStyle(gradePointColor(point.value))
                            .symbolSize(40)
                        }
                    } else {
                        // All subjects: scatter plot, colored by subject
                        let subjects = Array(Set(chartGrades.map(\.subject)))
                        let palette: [Color] = [NotoTheme.Colors.brand, NotoTheme.Colors.success, NotoTheme.Colors.warning, NotoTheme.Colors.danger, .purple, .orange, .teal]
                        ForEach(Array(subjects.enumerated()), id: \.element) { index, subject in
                            let subjectGrades = chartGrades.filter { $0.subject == subject }
                            ForEach(subjectGrades, id: \.date) { point in
                                PointMark(
                                    x: .value("Date", point.date),
                                    y: .value("Note", point.value)
                                )
                                .foregroundStyle(palette[index % palette.count])
                                .symbolSize(32)
                            }
                            LineMark(
                                x: .value("Date", subjectGrades.first?.date ?? Date()),
                                y: .value("Note", subjectGrades.first?.value ?? 10)
                            )
                            .foregroundStyle(palette[index % palette.count].opacity(0))
                            .annotation { EmptyView() }
                        }
                    }
                }
                .chartYScale(domain: 0...20)
                .chartYAxis {
                    AxisMarks(values: [0, 5, 10, 15, 20]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(NotoTheme.Colors.mist.opacity(0.2))
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(NotoTheme.Colors.mist.opacity(0.2))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                            .font(.system(size: 10))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                .frame(height: 200)
                .animation(.easeInOut(duration: 0.4), value: selectedSubject)
            }
        }
        .padding(NotoTheme.Spacing.lg)
        .notoCard()
    }

    // MARK: - Subject Averages Card

    private var subjectAveragesCard: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
            Text("Moyennes par matière")
                .font(NotoTheme.Typography.headline)

            let hasClassData = subjectAverages.contains { $0.classAverage != nil }

            Chart {
                ForEach(subjectAverages, id: \.subject) { item in
                    // Student bar
                    BarMark(
                        x: .value("Note", item.average),
                        y: .value("Matière", shortSubject(item.subject)),
                        height: hasClassData ? .fixed(12) : .automatic
                    )
                    .foregroundStyle(averageColor(item.average).gradient)
                    .cornerRadius(3)
                    .position(by: .value("Qui", "Moi"))
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            Text(String(format: "%.1f", item.average))
                                .font(NotoTheme.Typography.dataSmall)
                                .foregroundStyle(averageColor(item.average))
                            if let trend = item.trend {
                                Image(systemName: trend > 0 ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(trend > 0 ? NotoTheme.Colors.success : NotoTheme.Colors.danger)
                            }
                        }
                    }

                    // Class average bar
                    if let ca = item.classAverage {
                        BarMark(
                            x: .value("Note", ca),
                            y: .value("Matière", shortSubject(item.subject)),
                            height: .fixed(12)
                        )
                        .foregroundStyle(NotoTheme.Colors.mist.opacity(0.3))
                        .cornerRadius(3)
                        .position(by: .value("Qui", "Classe"))
                        .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                            Text(String(format: "%.1f", ca))
                                .font(.system(size: 10))
                                .foregroundStyle(NotoTheme.Colors.mist)
                        }
                    }
                }
            }
            .chartXScale(domain: 0...20)
            .chartXAxis {
                AxisMarks(values: [0, 5, 10, 15, 20]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(NotoTheme.Colors.mist.opacity(0.2))
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)")
                                .font(.system(size: 10))
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 11))
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                }
            }
            .chartForegroundStyleScale([
                "Moi": NotoTheme.Colors.brand,
                "Classe": NotoTheme.Colors.mist.opacity(0.4)
            ])
            .chartLegend(hasClassData ? .visible : .hidden)
            .frame(height: CGFloat(subjectAverages.count) * (hasClassData ? 52 : 38) + 20)
            .animation(.spring(response: 0.5), value: subjectAverages.map(\.average))

            if let avg = generalAverage {
                HStack(spacing: NotoTheme.Spacing.xs) {
                    Rectangle()
                        .fill(NotoTheme.Colors.brand.opacity(0.4))
                        .frame(width: 16, height: 2)
                    Text("Moyenne générale \(String(format: "%.1f", avg))/20")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
        }
        .padding(NotoTheme.Spacing.lg)
        .notoCard()
    }

    // MARK: - Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
            Text("Tendances détectées")
                .font(NotoTheme.Typography.headline)

            ForEach(allInsights, id: \.insight.id) { item in
                InsightRow(
                    insight: item.insight,
                    showChild: children.count > 1,
                    childName: item.child.firstName,
                    onNavigateToHomework: onNavigateToHomework,
                    onShowTrendSheet: { showTrendSheet = item.insight },
                    onNavigateToDiscover: onNavigateToDiscover
                )
            }
        }
    }

    // MARK: - Helpers

    private func averageColor(_ avg: Double) -> Color {
        if avg >= 14 { return NotoTheme.Colors.success }
        if avg >= 10 { return NotoTheme.Colors.brand }
        if avg >= 8  { return NotoTheme.Colors.warning }
        return NotoTheme.Colors.danger
    }

    private func gradePointColor(_ value: Double) -> Color {
        if value >= 14 { return NotoTheme.Colors.success }
        if value >= 10 { return NotoTheme.Colors.brand }
        if value >= 8  { return NotoTheme.Colors.warning }
        return NotoTheme.Colors.danger
    }

    private func averageLabel(_ avg: Double) -> String {
        if avg >= 16 { return "Excellent" }
        if avg >= 14 { return "Très bien" }
        if avg >= 12 { return "Bien" }
        if avg >= 10 { return "Satisfaisant" }
        if avg >= 8  { return "À surveiller" }
        return "En difficulté"
    }

    private func shortSubject(_ subject: String) -> String {
        let s = subject.lowercased()
        if s.contains("math") { return "Maths" }
        if s.contains("français") || s.contains("franc") { return "Français" }
        if s.contains("hist") { return "Hist-Géo" }
        if s.contains("phys") { return "Physique" }
        if s.contains("svt") || s.contains("biolog") { return "SVT" }
        if s.contains("anglais") { return "Anglais" }
        if s.contains("espagnol") { return "Espagnol" }
        if s.contains("allemand") { return "Allemand" }
        if s.contains("philosophi") { return "Philo" }
        if s.contains("music") { return "Musique" }
        if s.contains("art") { return "Arts" }
        if s.contains("sport") || s.contains("eps") { return "EPS" }
        if s.contains("info") || s.contains("nsi") { return "Info" }
        if s.contains("eco") || s.contains("ses") { return "SES" }
        return String(subject.prefix(10))
    }
}

// MARK: - Insight Row

private struct InsightRow: View {
    let insight: Insight
    let showChild: Bool
    let childName: String
    var onNavigateToHomework: (() -> Void)?
    var onShowTrendSheet: (() -> Void)?
    var onNavigateToDiscover: ((_ subject: String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
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

            if let ctaLabel {
                Button(action: ctaAction) {
                    Text(ctaLabel)
                        .font(NotoTheme.Typography.caption)
                }
                .buttonStyle(.bordered)
                .tint(NotoTheme.Colors.brand)
            }
        }
        .padding(NotoTheme.Spacing.md)
        .notoCard()
    }

    private var ctaLabel: String? {
        switch insight.type {
        case .difficulty: "Voir les devoirs à venir"
        case .trend: "Voir la progression"
        case .strength: "Découvrir des ressources"
        case .alert: nil
        }
    }

    private func ctaAction() {
        switch insight.type {
        case .difficulty: onNavigateToHomework?()
        case .trend: onShowTrendSheet?()
        case .strength: onNavigateToDiscover?(insight.subject)
        case .alert: break
        }
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

// MARK: - Trend Detail Sheet

// MARK: - ENT Stat Tile

private struct ENTStatTile: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            Text(value)
                .font(NotoTheme.Typography.data)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text(label)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(NotoTheme.Spacing.md)
        .notoCard()
    }
}

private struct TrendDetailSheet: View {
    let insight: Insight
    let grades: [Grade]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    // Chart
                    if grades.count >= 2 {
                        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                            Text("Évolution — \(insight.subject)")
                                .font(NotoTheme.Typography.headline)

                            Chart {
                                RuleMark(y: .value("Seuil", 10))
                                    .foregroundStyle(Color.red.opacity(0.2))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))

                                // Class average line
                                ForEach(grades.sorted { $0.date < $1.date }, id: \.id) { grade in
                                    if let ca = grade.classAverage {
                                        LineMark(
                                            x: .value("Date", grade.date),
                                            y: .value("Classe", ca),
                                            series: .value("Série", "Classe")
                                        )
                                        .foregroundStyle(NotoTheme.Colors.mist.opacity(0.5))
                                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                        .interpolationMethod(.catmullRom)
                                    }
                                }

                                ForEach(grades.sorted { $0.date < $1.date }, id: \.id) { grade in
                                    AreaMark(
                                        x: .value("Date", grade.date),
                                        y: .value("Note", grade.normalizedValue)
                                    )
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [NotoTheme.Colors.brand.opacity(0.25), .clear],
                                            startPoint: .top, endPoint: .bottom
                                        )
                                    )
                                    .interpolationMethod(.catmullRom)

                                    LineMark(
                                        x: .value("Date", grade.date),
                                        y: .value("Note", grade.normalizedValue)
                                    )
                                    .foregroundStyle(NotoTheme.Colors.brand)
                                    .interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                                    PointMark(
                                        x: .value("Date", grade.date),
                                        y: .value("Note", grade.normalizedValue)
                                    )
                                    .foregroundStyle(gradeColor(grade.normalizedValue))
                                    .symbolSize(50)
                                    .annotation(position: .top) {
                                        Text(String(format: "%.1f", grade.normalizedValue))
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(gradeColor(grade.normalizedValue))
                                    }
                                }
                            }
                            .chartYScale(domain: 0...20)
                            .chartYAxis {
                                AxisMarks(values: [0, 5, 10, 15, 20]) { value in
                                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                        .foregroundStyle(NotoTheme.Colors.mist.opacity(0.2))
                                    AxisValueLabel {
                                        if let v = value.as(Int.self) { Text("\(v)").font(.system(size: 10)) }
                                    }
                                }
                            }
                            .frame(height: 220)
                        }
                        .padding(NotoTheme.Spacing.md)
                        .notoCard()
                    }

                    // Stats
                    let sorted = grades.sorted { $0.date < $1.date }
                    let avg = grades.reduce(0.0) { $0 + $1.normalizedValue } / Double(grades.count)
                    let best = grades.map(\.normalizedValue).max() ?? 0
                    let worst = grades.map(\.normalizedValue).min() ?? 0
                    let classAvgs = grades.compactMap(\.classAverage)
                    let classAvg = classAvgs.isEmpty ? nil : classAvgs.reduce(0, +) / Double(classAvgs.count)

                    HStack(spacing: NotoTheme.Spacing.md) {
                        statTile(label: "Ma moyenne", value: String(format: "%.1f", avg), color: gradeColor(avg))
                        statTile(label: "Meilleure", value: String(format: "%.1f", best), color: NotoTheme.Colors.success)
                        statTile(label: "Plus faible", value: String(format: "%.1f", worst), color: NotoTheme.Colors.danger)
                    }

                    if let ca = classAvg {
                        HStack(spacing: NotoTheme.Spacing.sm) {
                            Rectangle()
                                .fill(NotoTheme.Colors.mist.opacity(0.5))
                                .frame(width: 20, height: 2)
                                .overlay(
                                    HStack(spacing: 3) {
                                        ForEach(0..<3, id: \.self) { _ in
                                            Rectangle().frame(width: 4, height: 2)
                                        }
                                    }
                                )
                            Text("Moyenne de la classe : \(String(format: "%.1f", ca))/20")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                            Spacer()
                            let diff = avg - ca
                            Text(diff >= 0 ? "+\(String(format: "%.1f", diff))" : String(format: "%.1f", diff))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(diff >= 0 ? NotoTheme.Colors.success : NotoTheme.Colors.danger)
                        }
                        .padding(NotoTheme.Spacing.sm)
                        .background(NotoTheme.Colors.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                    }

                    Text(insight.value)
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(NotoTheme.Spacing.md)
                        .background(NotoTheme.Colors.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                }
                .padding(NotoTheme.Spacing.md)
            }
            .navigationTitle("Progression")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private func statTile(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(NotoTheme.Typography.mono(22, weight: .bold))
                .foregroundStyle(color)
            Text("/20")
                .font(.system(size: 11))
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            Text(label)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm).stroke(NotoTheme.Colors.border, lineWidth: 0.5))
    }

    private func gradeColor(_ v: Double) -> Color {
        if v >= 14 { return NotoTheme.Colors.success }
        if v >= 10 { return NotoTheme.Colors.brand }
        if v >= 8  { return NotoTheme.Colors.warning }
        return NotoTheme.Colors.danger
    }
}
