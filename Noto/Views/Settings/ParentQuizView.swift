import SwiftUI
import SwiftData

/// « Testez-vous sur son programme » : the parent plays the child's quiz
/// (`ParentQuizSession`, same draw and same question screen as `QuizView`),
/// then sees the score, the correction and where the child stands on the
/// same notions. Parent tone (vouvoiement). Earns nothing and never changes
/// the child's progress. Closing mid-quiz saves nothing.
struct ParentQuizView: View {
    let child: Child
    /// Injected by previews; production draws a random seed.
    var seed: UInt64?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var session: ParentQuizSession? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    content(for: session)
                } else {
                    ProgressView("Préparation des questions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(NotoTheme.Colors.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if session?.phase != .finished {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(minWidth: ChildStyle.minTapTarget, minHeight: ChildStyle.minTapTarget)
                        }
                        .accessibilityLabel("Arrêter le quiz")
                    }
                }
            }
        }
        .task {
            if session == nil { await startSession() }
        }
    }

    private func startSession() async {
        // Same on-device generation as the child's quiz (3.3), no network.
        let generator = QuizGenerator()
        if let seed {
            session = await ParentQuizSession.make(child: child, modelContext: modelContext, seed: seed,
                                                   generator: generator)
        } else {
            session = await ParentQuizSession.make(child: child, modelContext: modelContext, generator: generator)
        }
    }

    @ViewBuilder
    private func content(for session: ParentQuizSession) -> some View {
        switch session.phase {
        case .empty:
            ScrollView {
                VStack(spacing: NotoTheme.Spacing.lg) {
                    ChildEmptyState(systemImage: "tray",
                                    title: "Pas encore de questions",
                                    message: "Les questions du niveau de \(child.firstName) ne sont pas encore "
                                        + "disponibles sur cet appareil. Réessayez un peu plus tard.")
                    ChildPrimaryButton(title: "Retour") { dismiss() }
                }
                .padding(NotoTheme.Spacing.md)
            }
        case .inProgress:
            if let question = session.currentQuestion {
                QuizQuestionScreen(session: session, question: question, copy: .parent)
                    .id(question.id)
            }
        case .finished:
            if let result = session.result {
                ParentQuizResultView(result: result, childName: child.firstName,
                                     childLinked: child.receivesFamilySync,
                                     onDone: { dismiss() },
                                     onAnotherQuiz: {
                                         self.session = nil
                                         Task { await startSession() }
                                     })
            }
        }
    }
}

/// Score, where the child stands on the same notions, then the correction.
struct ParentQuizResultView: View {
    let result: ParentQuizResult
    let childName: String
    var childLinked = false
    let onDone: () -> Void
    var onAnotherQuiz: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                VStack(spacing: NotoTheme.Spacing.sm) {
                    Text(Self.title(correct: result.correctCount, total: result.totalCount))
                        .font(ChildStyle.title)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(result.correctCount) / \(result.totalCount)")
                        .font(ChildStyle.figure)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .accessibilityLabel(Self.scoreSentence(correct: result.correctCount,
                                                               total: result.totalCount))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, NotoTheme.Spacing.lg)

                if let sentence = result.comparison.sentence(firstName: childName, linked: childLinked) {
                    Label(sentence, systemImage: "person.2")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(NotoTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .signalCard(.info)
                }

                VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                    Text("Correction")
                        .font(ChildStyle.subject)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(result.review) { item in
                        reviewRow(item)
                    }
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

                PrivacyNoticeCard(
                    text: "Vos réponses restent sur cet appareil. Elles ne comptent ni dans les récompenses "
                        + "ni dans le suivi de votre enfant."
                )
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
    }

    private func display(_ raw: String, generated: Bool) -> AttributedString {
        generated ? AttributedString(raw) : BankText.attributed(raw)
    }

    private func reviewRow(_ item: ParentQuizReviewItem) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            Label {
                Text(display(item.question, generated: item.isGenerated))
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: item.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(item.isCorrect ? NotoTheme.Colors.success : NotoTheme.Colors.danger)
            }
            if let subject = item.subject {
                Text([subject, item.theme].compactMap { $0 }.joined(separator: " · "))
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            if !item.isCorrect, let chosen = item.chosenAnswer {
                Text("Votre réponse : \(BankText.plain(chosen))")
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Text("Bonne réponse : \(BankText.plain(item.rightAnswer))")
                .font(ChildStyle.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            if let explanation = item.explanation, !explanation.isEmpty {
                Text(display(explanation, generated: item.isGenerated))
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isCorrect ? "Bonne réponse" : "Erreur")
    }

    // MARK: - Copy (parent tone)

    static func title(correct: Int, total: Int) -> String {
        guard total > 0 else { return "Quiz terminé" }
        if correct == total { return "Sans faute !" }
        if Double(correct) >= 0.6 * Double(total) { return "Bien joué" }
        return "De quoi réviser ensemble"
    }

    static func scoreSentence(correct: Int, total: Int) -> String {
        let questions = total == 1 ? "question" : "questions"
        return "Vous avez répondu juste à \(correct) \(questions) sur \(total)."
    }
}

#Preview("Quiz parent") {
    let child = PreviewData.revisionChild
    return ParentQuizView(child: child, seed: 42)
        .withPreviewData()
}
