import SwiftUI

/// End of a quiz: score, minutes added to the cagnotte or, when none, the
/// reason in friendly child wording (tutoiement). The wording stays neutral
/// on unlocking: whether the minutes unlock now, wait for the end of class or
/// for the daily budget is said on the home (`ChildHomeView`, 3.4), which
/// knows the Screen Time setup. XP and subject level-ups
/// (3.6) are shown when the quiz earned some.
struct QuizResultView: View {
    let result: QuizSessionResult
    let onDone: () -> Void
    var onAnotherQuiz: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: NotoTheme.Spacing.lg) {
                Image(systemName: Self.symbol(for: result))
                    .font(.system(.largeTitle))
                    .foregroundStyle(result.decision.countsAsSuccess ? NotoTheme.Colors.success : NotoTheme.Colors.info)
                    .padding(.top, NotoTheme.Spacing.lg)
                    .accessibilityHidden(true)

                Text(Self.title(for: result))
                    .font(ChildStyle.title)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text("\(result.correctCount) / \(result.totalCount)")
                    .font(ChildStyle.figure)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .accessibilityLabel("\(result.correctCount) bonnes réponses sur \(result.totalCount)")

                minutesCard

                if result.xpEarned > 0 || !result.levelUps.isEmpty {
                    xpCard
                }

                VStack(spacing: NotoTheme.Spacing.sm) {
                    ChildPrimaryButton(title: "Terminer", action: onDone)
                    if let onAnotherQuiz {
                        Button(action: onAnotherQuiz) {
                            Text("Un autre quiz")
                                .font(ChildStyle.headline)
                                .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(NotoTheme.Colors.textPrimary)
                    }
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
    }

    private var minutesCard: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            if result.minutesEarned > 0 {
                Text("+\(result.minutesEarned) min dans ta cagnotte")
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                if result.decision.bonus > 0 {
                    Text("Dont \(result.decision.bonus) min de bonus : bon courage pour ton contrôle de demain !")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            } else {
                Text(Self.message(for: result))
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .signalCard(result.minutesEarned > 0 ? .positive : .info)
        .accessibilityElement(children: .combine)
    }

    private var xpCard: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(NotoTheme.Colors.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                Text("+\(result.xpEarned) XP")
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                ForEach(result.levelUps, id: \.subject) { levelUp in
                    Text(Self.levelUpText(levelUp))
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.xpAccessibilityLabel(for: result))
    }

    // MARK: - Copy (pure, tested through `QuizResultCopyTests`)

    static func levelUpText(_ levelUp: SubjectLevelUp) -> String {
        "Niveau \(levelUp.level) en \(levelUp.subject) !"
    }

    static func xpAccessibilityLabel(for result: QuizSessionResult) -> String {
        (["\(result.xpEarned) points d'expérience gagnés"] + result.levelUps.map(levelUpText))
            .joined(separator: ". ")
    }


    static func title(for result: QuizSessionResult) -> String {
        if result.totalCount > 0, result.correctCount == result.totalCount { return "Sans faute, bravo !" }
        if result.decision.countsAsSuccess { return "Bien joué !" }
        return "Merci d'avoir révisé !"
    }

    static func symbol(for result: QuizSessionResult) -> String {
        result.decision.countsAsSuccess ? "star.fill" : "leaf.fill"
    }

    /// Why no minute was added, in a warm, pressure-free tone.
    static func message(for result: QuizSessionResult) -> String {
        switch result.decision.denial {
        case .belowThreshold:
            return "Il fallait \(result.requiredCorrect) bonnes réponses pour gagner des minutes. "
                + "Ce que tu viens de revoir compte quand même : ces notions reviendront bientôt."
        case .tooFast:
            return "Tu as répondu super vite ! La prochaine fois, prends le temps de bien lire "
                + "chaque question pour gagner des minutes."
        case .identicalReplay:
            return "Tu as déjà réussi exactement ces questions : pas de minutes cette fois. "
                + "De nouvelles questions arrivent bientôt."
        case .tiersExhausted, .capReached:
            return "Ta cagnotte du jour est pleine. Tes révisions comptent quand même pour ta série !"
        case .emptyQuiz:
            return "Il n'y avait pas de question cette fois."
        case .tooShort:
            return "Ce quiz était un peu court (\(result.totalCount) question\(result.totalCount > 1 ? "s" : "")) : "
                + "il en faut \(result.minQuestionCount) pour gagner des minutes. Ce que tu as revu compte quand même, "
                + "et d'autres questions arrivent bientôt."
        case nil:
            return "Pas de minutes cette fois."
        }
    }
}

#Preview("Réussi") {
    QuizResultView(
        result: QuizSessionResult(correctCount: 5, totalCount: 5, durationSec: 95,
                                  decision: RewardDecision(base: 10, bonus: 5, denial: nil, countsAsSuccess: true),
                                  requiredCorrect: 4, xpEarned: 54,
                                  levelUps: [SubjectLevelUp(subject: "Mathématiques", level: 2)]),
        onDone: {}, onAnotherQuiz: {}
    )
}

#Preview("Pas assez de bonnes réponses") {
    QuizResultView(
        result: QuizSessionResult(correctCount: 2, totalCount: 5, durationSec: 80,
                                  decision: .denied(.belowThreshold), requiredCorrect: 4, xpEarned: 20),
        onDone: {}
    )
}

#Preview("Cagnotte pleine") {
    QuizResultView(
        result: QuizSessionResult(correctCount: 4, totalCount: 5, durationSec: 70,
                                  decision: .denied(.capReached), requiredCorrect: 4),
        onDone: {}
    )
}
