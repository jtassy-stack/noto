import SwiftUI
import SwiftData

/// Accueil parent, « Cette semaine »: one child's week as data viz. The
/// synthesis line, revisions (days revised, 4-week activity, série), the
/// programme notions per subject, the general average over 8 weeks, the
/// weakest notion with « Testez-vous », what the child studies in class now
/// with a Découvrir link, and the anti-cheat rule. Parent tone (vouvoiement).
///
/// Data locality (V1): quizzes and notions exist only on the device where the
/// child plays; on another device the revision cards say so instead of
/// showing zeros. Grades and the cahier de textes are on every device.
struct ParentWeekSection: View {
    let child: Child
    @Query private var recos: [CultureReco]
    @State private var showParentQuiz = false
    @State private var showChildView = false

    var body: some View {
        let now = Date()
        let calendar = Calendar.current
        let summary = RevisionReportStore.summary(for: child, now: now, calendar: calendar)
        let attempts = GamificationStore.attempts(of: child)
        let revises = CurriculumService.revisionLevels.contains(CurriculumService.canonicalLevel(child.grade))
        let subjects = revises
            ? SubjectProgress.path(level: child.grade, specialties: child.specialties,
                                   masteries: child.notionMasteries.map { MasterySnapshot($0) },
                                   curriculum: CurriculumSnapshot.bundled)
            : []
        let bars = ParentWeekReport.notionBars(subjects)
        let weakest = ParentWeekReport.weakestTheme(subjects)
        let history = ParentWeekReport.averageHistory(child.grades.map { ParentWeekReport.GradePoint($0) },
                                                      now: now, calendar: calendar)
        let revisedDays = summary.isActive
            ? ParentWeekReport.revisedDays(attempts: attempts, now: now, calendar: calendar) : nil
        let studied = ParentWeekReport.studiedNow(ProgrammePositionSection.position(for: child, now: now,
                                                                                    calendar: calendar))

        VStack(alignment: .leading, spacing: NotoTheme.Spacing.cardGap) {
            if let line = ParentWeekReport.synthesis(firstName: child.firstName, revisedDays: revisedDays,
                                                     averageHistory: history, fragileSubject: weakest?.subject) {
                Text(line)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if revises {
                if summary.isActive {
                    revisionCard(summary: summary,
                                 levels: ParentWeekReport.activityLevels(attempts: attempts, now: now,
                                                                         calendar: calendar),
                                 revisedDays: revisedDays ?? 0)
                    if !bars.isEmpty { notionsCard(bars) }
                } else {
                    Text(Self.noRevisionText(child.firstName))
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(NotoTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .notoCard()
                }
            }

            if let last = history.last {
                averageCard(current: last, history: history)
            }

            if summary.isActive, let weakest {
                fragileCard(theme: weakest.theme)
            }

            if let studied {
                studiedCard(studied)
            }

            if summary.isActive {
                Text("Les quiz refaits à l'identique ne rapportent ni minutes ni XP.")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            childViewButton
        }
        .fullScreenCover(isPresented: $showParentQuiz) {
            ParentQuizView(child: child)
        }
        // Vision enfant: the child app, read only, on this child's data.
        .fullScreenCover(isPresented: $showChildView) {
            ChildHomeView(previewChild: child)
        }
    }

    private var childViewButton: some View {
        Button {
            showChildView = true
        } label: {
            Label(ChildPreviewBanner.entryTitle(child.firstName), systemImage: "eye")
                .font(NotoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(NotoTheme.Colors.info)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityHint("Affiche ce que \(child.firstName) voit dans nōto, en lecture seule.")
    }

    static func noRevisionText(_ name: String) -> String {
        "Les révisions de \(name) s'affichent sur l'appareil où \(name) fait ses quiz."
    }

    // MARK: - Révisions

    private func revisionCard(summary: RevisionSummary, levels: [Int], revisedDays: Int) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Révisions").sectionLabelStyle()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(revisedDays) jour\(revisedDays > 1 ? "s" : "")")
                            .font(NotoTheme.Typography.dataLarge)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("sur 7")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                if summary.streakDays > 1 {
                    Text("série de \(summary.streakDays) jours")
                        .font(NotoTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(NotoTheme.Colors.success)
                        .padding(.top, 4)
                }
            }
            .accessibilityElement(children: .combine)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.activityColor(level))
                        .frame(height: 22)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.activityAccessibilityLabel(levels))

            HStack {
                Text("il y a 4 semaines")
                Spacer()
                Text("\(summary.quizzes7d) quiz · \(summary.minutesEarned7d) min gagnées")
            }
            .font(NotoTheme.Typography.caption)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    static func activityColor(_ level: Int) -> Color {
        switch level {
        case 0: NotoTheme.Colors.surfaceSecondary
        case 1: NotoTheme.Colors.brand.opacity(0.25)
        case 2: NotoTheme.Colors.brand.opacity(0.6)
        default: NotoTheme.Colors.brand
        }
    }

    static func activityAccessibilityLabel(_ levels: [Int]) -> String {
        let days = levels.filter { $0 > 0 }.count
        return "Activité de révision sur 4 semaines : \(days) jour\(days > 1 ? "s" : "") avec au moins un quiz"
    }

    // MARK: - Notions

    private func notionsCard(_ bars: [ParentWeekReport.NotionBar]) -> some View {
        let widest = max(1, bars.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Notions du programme").sectionLabelStyle()
            ForEach(bars) { bar in
                HStack(spacing: NotoTheme.Spacing.sm) {
                    Text(bar.subject)
                        .font(NotoTheme.Typography.caption.weight(.medium))
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .leading)
                    GeometryReader { proxy in
                        let unit = proxy.size.width / CGFloat(widest)
                        HStack(spacing: 0) {
                            Rectangle().fill(NotoTheme.Colors.success).frame(width: unit * CGFloat(bar.mastered))
                            Rectangle().fill(NotoTheme.Colors.brand.opacity(0.35))
                                .frame(width: unit * CGFloat(bar.inProgress))
                            Rectangle().fill(NotoTheme.Colors.warning).frame(width: unit * CGFloat(bar.fragile))
                            Spacer(minLength: 0)
                        }
                        .background(NotoTheme.Colors.surfaceSecondary)
                        .clipShape(Capsule())
                    }
                    .frame(height: 12)
                    Text("\(bar.total)")
                        .font(NotoTheme.Typography.caption.monospacedDigit())
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .frame(width: 28, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bar.subject) : \(bar.mastered) maîtrisées, \(bar.inProgress) en cours, "
                                    + "\(bar.fragile) fragiles")
            }
            HStack(spacing: 14) {
                legend(NotoTheme.Colors.success, "maîtrisées")
                legend(NotoTheme.Colors.brand.opacity(0.35), "en cours")
                legend(NotoTheme.Colors.warning, "fragiles")
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
        .font(NotoTheme.Typography.caption)
        .foregroundStyle(NotoTheme.Colors.textSecondary)
    }

    // MARK: - Moyenne

    private func averageCard(current: Double, history: [Double]) -> some View {
        let trend = ParentWeekReport.averageTrendText(history)
        let delta = (history.last ?? 0) - (history.first ?? 0)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Moyenne").sectionLabelStyle()
                Text(ParentWeekReport.averageText(current))
                    .font(NotoTheme.Typography.dataLarge)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                if let trend {
                    Text(trend)
                        .font(NotoTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(delta >= ParentWeekReport.trendThreshold ? NotoTheme.Colors.success
                                         : NotoTheme.Colors.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if history.count > 1 {
                Sparkline(values: history)
                    .frame(width: 170, height: 60)
                    .accessibilityLabel("Moyenne de \(ParentWeekReport.averageText(history.first ?? 0)) "
                                        + "à \(ParentWeekReport.averageText(current)) sur \(history.count - 1) semaines")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    // MARK: - Notion fragile

    private func fragileCard(theme: String) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("La notion « \(theme) » reste fragile. Une révision dans les jours qui viennent l'aidera à tenir.")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Testez-vous sur son programme") { showParentQuiz = true }
                .font(NotoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(NotoTheme.Colors.info)
                .frame(minHeight: 44, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .signalCard(.attention)
    }

    // MARK: - Ce que l'enfant étudie

    private func studiedCard(_ sighting: ProgrammePosition.Sighting) -> some View {
        let reco = Self.reco(for: sighting, child: child, in: recos)
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Ce que \(child.firstName) étudie")
                .font(NotoTheme.Typography.sectionLabel)
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(NotoTheme.Colors.info)
            VStack(alignment: .leading, spacing: 2) {
                Text(sighting.theme)
                    .font(NotoTheme.Typography.human(20))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(sighting.subject)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            if let reco {
                Text("À découvrir : \(reco.title)")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Voir dans Découvrir") {
                NotificationCenter.default.post(name: .navigateToDiscover, object: nil)
            }
            .font(NotoTheme.Typography.body.weight(.semibold))
            .foregroundStyle(NotoTheme.Colors.info)
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .signalCard(.info)
    }

    /// A culture-api reco of this child on the theme, else on the subject.
    static func reco(for sighting: ProgrammePosition.Sighting, child: Child, in recos: [CultureReco],
                     now: Date = Date()) -> CultureReco? {
        let mine = recos.filter { $0.child?.persistentModelID == child.persistentModelID && $0.expiresAt > now }
        let theme = SubjectAlias.fold(sighting.theme)
        let subject = SubjectAlias.fold(sighting.subject)
        return mine.first { $0.linkedTheme.map { SubjectAlias.fold($0) } == theme }
            ?? mine.first { $0.linkedSubject.map { SubjectAlias.fold($0) } == subject }
    }
}

// MARK: - Sparkline

/// The average line, last point marked. Scaled to its own min/max with a
/// little headroom, so a small move stays visible.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values, in: proxy.size)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height - 1))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height - 1))
                }
                .stroke(NotoTheme.Colors.border, lineWidth: 1)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(NotoTheme.Colors.brand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle()
                        .fill(NotoTheme.Colors.brand)
                        .frame(width: 8, height: 8)
                        .position(last)
                }
            }
        }
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return [] }
        let span = max(hi - lo, 1)
        let inset: CGFloat = 6
        let height = size.height - inset * 2
        let step = (size.width - inset * 2) / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: inset + CGFloat(index) * step,
                    y: inset + height * (1 - CGFloat((value - lo) / span)))
        }
    }
}

extension ParentWeekReport.GradePoint {
    init(_ grade: Grade) {
        self.init(value: grade.value, outOf: grade.outOf, coefficient: grade.coefficient, date: grade.date)
    }
}
