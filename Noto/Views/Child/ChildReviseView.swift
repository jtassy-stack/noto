import SwiftUI

/// « Réviser », the child app's second tab: everything that is played.
/// The quiz of the day says what it is made of (`QuizSession.plan`: homework,
/// notions to review, programme), then the themes taught in class now (from
/// the cahier de textes, `ProgrammePosition`), then « Pour le plaisir »: the
/// culture question of the day and the culture G quiz, reward-free as
/// before. Child mode, tutoiement.
struct ChildReviseView: View {
    let child: Child?
    let plan: (plan: QuizPlan, position: ProgrammePosition)?
    let canQuiz: Bool
    let cultureQuestion: DailyCultureQuestion?
    let cultureQuizEnabled: Bool
    let onStartQuiz: () -> Void
    let onCultureAnswer: (Int) -> Void
    /// Opens « Parcours » on that subject.
    let onOpenSubject: (String) -> Void

    @State private var showCultureQuiz = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                Text("Réviser")
                    .font(ChildStyle.greeting)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, NotoTheme.Spacing.sm)

                dailyQuizCard

                if let position = plan?.position, position.hasAny {
                    inClassSection(position)
                }

                if cultureQuestion != nil || cultureQuizEnabled {
                    funSection
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
        .fullScreenCover(isPresented: $showCultureQuiz) {
            CultureQuizView(audience: .child(level: child.map { CurriculumService.canonicalLevel($0.grade) }))
        }
    }

    // MARK: - Quiz du jour

    @ViewBuilder
    private var dailyQuizCard: some View {
        if canQuiz {
            let lines = plan.map { Self.compositionLines($0.plan) } ?? []
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiz du jour")
                        .font(ChildStyle.title)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text("\(QuizSession.questionCount) questions · environ 3 min")
                        .font(ChildStyle.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .accessibilityElement(children: .combine)

                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                        ForEach(lines) { line in
                            HStack(spacing: NotoTheme.Spacing.sm) {
                                Circle()
                                    .fill(Self.color(for: line.kind))
                                    .frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                Text(line.text)
                                    .font(ChildStyle.body)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                ChildPrimaryButton(title: "Commencer", systemImage: "sparkles", action: onStartQuiz)
                    .accessibilityHint("Lance le quiz du jour")
            }
            .padding(NotoTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notoCard()
        } else {
            ChildEmptyState(systemImage: "tray",
                            title: "Les questions arrivent bientôt",
                            message: "On prépare des questions pour ta classe. Reviens un peu plus tard !")
        }
    }

    // MARK: - En classe en ce moment

    private func inClassSection(_ position: ProgrammePosition) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("En classe en ce moment")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(position.orderedSubjects.enumerated()), id: \.element.subject) { index, subject in
                    if index > 0 { SettingsDivider() }
                    Button {
                        onOpenSubject(subject.subject)
                    } label: {
                        HStack(spacing: NotoTheme.Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subject.subject)
                                    .font(ChildStyle.subject)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                if let theme = subject.current.first?.theme {
                                    Text(theme)
                                        .font(ChildStyle.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(ChildStyle.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 12)
                        .frame(minHeight: ChildStyle.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Ouvre ton parcours dans cette matière")
                }
            }
            .notoCard()
        }
    }

    // MARK: - Pour le plaisir

    private var funSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Pour le plaisir")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)
            if let cultureQuestion {
                CultureQuestionCard(question: cultureQuestion, onAnswer: onCultureAnswer)
            }
            if cultureQuizEnabled {
                cultureQuizCard
            }
        }
    }

    /// Entry to the culture G quiz (10 Koi questions, child-filtered pool,
    /// reward-free), shown when the parent turned culture on.
    private var cultureQuizCard: some View {
        Button {
            showCultureQuiz = true
        } label: {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(NotoTheme.Colors.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiz culture G")
                        .font(ChildStyle.headline)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text("10 questions pour le plaisir : cinéma, livres, sport, sciences…")
                        .font(ChildStyle.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(NotoTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget, alignment: .leading)
            .notoCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composition (pure, tested through `ChildReviseCopyTests`)

    struct CompositionLine: Identifiable, Equatable, Sendable {
        enum Kind: Sendable { case homework, review, programme }
        let kind: Kind
        let count: Int
        let text: String
        var id: Kind { kind }
    }

    /// What the planned slots are about, in plan order (homework, then due
    /// notions, then programme). A plan slot the bank cannot fill is topped
    /// up from the rest of the level, so the lines describe the intent.
    static func compositionLines(_ plan: QuizPlan) -> [CompositionLine] {
        let homework = plan.slots.filter(\.isHomework).count
        let review = plan.slots.filter { $0.origin == .dueNotion }.count
        let programme = plan.slots.filter { $0.origin == .programme }.count
        let tomorrowOnly = homework > 0
            && plan.slots.filter(\.isHomework).allSatisfy { $0.origin == .homeworkTomorrow }
        var lines: [CompositionLine] = []
        if homework > 0 {
            lines.append(CompositionLine(kind: .homework, count: homework,
                                         text: "\(homework) sur tes devoirs \(tomorrowOnly ? "de demain" : "à venir")"))
        }
        if review > 0 {
            lines.append(CompositionLine(kind: .review, count: review,
                                         text: review == 1 ? "1 notion à revoir" : "\(review) notions à revoir"))
        }
        if programme > 0 {
            lines.append(CompositionLine(kind: .programme, count: programme,
                                         text: "\(programme) sur ton programme"))
        }
        return lines
    }

    /// Cobalt = à revoir (an information, never amber: amber is the série).
    static func color(for kind: CompositionLine.Kind) -> Color {
        switch kind {
        case .homework: ChildStyle.accent
        case .review: NotoTheme.Colors.info
        case .programme: NotoTheme.Colors.textTertiary
        }
    }
}
