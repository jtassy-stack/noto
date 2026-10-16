import SwiftUI
import SwiftData

/// One quiz, one question per screen: four choices, no clock on screen (no
/// pressure; rushed quizzes are handled by the `tooFast` rule), immediate
/// feedback with the explanation, then `QuizResultView`. Closing mid-quiz saves nothing.
/// Child mode: every string addresses the child (tutoiement).
struct QuizView: View {
    let child: Child
    /// Injected by previews / tests; production draws a random seed.
    var seed: UInt64?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var session: QuizSession? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    content(for: session)
                } else {
                    ProgressView()
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
        .onAppear {
            if session == nil { startSession() }
        }
    }

    private func startSession() {
        // The parent's rules, read once per quiz from the app group.
        let config = RewardConfigStore.load()
        if let seed {
            session = QuizSession(child: child, modelContext: modelContext, config: config, seed: seed)
        } else {
            session = QuizSession(child: child, modelContext: modelContext, config: config)
        }
    }

    @ViewBuilder
    private func content(for session: QuizSession) -> some View {
        switch session.phase {
        case .empty:
            ScrollView {
                VStack(spacing: NotoTheme.Spacing.lg) {
                    ChildEmptyState(systemImage: "tray",
                                    title: "Les questions arrivent bientôt",
                                    message: "On prépare des questions pour ta classe. Reviens un peu plus tard !")
                    ChildPrimaryButton(title: "Retour") { dismiss() }
                }
                .padding(NotoTheme.Spacing.md)
            }
        case .inProgress:
            if let question = session.currentQuestion {
                QuestionScreen(session: session, question: question)
                    .id(question.id)
            }
        case .finished:
            if let result = session.result {
                QuizResultView(result: result,
                               onDone: { dismiss() },
                               onAnotherQuiz: { startSession() })
            }
        }
    }
}

/// The current question, its choices and the feedback once answered.
private struct QuestionScreen: View {
    let session: QuizSession
    let question: QuizQuestion

    private static let letters = ["A", "B", "C", "D"]

    private enum Focus: Hashable { case question, feedback }
    @AccessibilityFocusState private var focus: Focus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                header

                Text(BankText.attributed(question.question))
                    .font(ChildStyle.question)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .question)

                VStack(spacing: NotoTheme.Spacing.sm) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                        choiceButton(index: index, text: choice)
                    }
                }

                if let chosen = session.currentAnswer {
                    feedback(chosen: chosen)
                        .accessibilityFocused($focus, equals: .feedback)
                    ChildPrimaryButton(title: session.isLastQuestion ? "Voir mon résultat" : "Question suivante",
                                       systemImage: "arrow.right") {
                        session.advance()
                    }
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .onAppear {
            // The screen is rebuilt per question (`.id`): bring VoiceOver
            // back to the new question rather than the previous button.
            if session.currentIndex > 0 { moveFocus(to: .question) }
        }
    }

    /// Deferred one beat so the target exists in the accessibility tree.
    private func moveFocus(to target: Focus) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            focus = target
        }
    }

    // MARK: Header (progress)

    private var header: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Question \(session.currentIndex + 1) sur \(session.questions.count)")
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            ProgressView(value: Double(session.currentIndex + (session.currentAnswer == nil ? 0 : 1)),
                         total: Double(max(1, session.questions.count)))
                .tint(ChildStyle.accent)
                .accessibilityHidden(true)
            if let subject = question.subject {
                Text(subject)
                    .font(ChildStyle.subject)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: Choices

    private enum ChoiceState { case idle, correct, wrongChosen, dimmed }

    private func state(of index: Int) -> ChoiceState {
        guard let chosen = session.currentAnswer else { return .idle }
        if index == question.answerIndex { return .correct }
        if index == chosen { return .wrongChosen }
        return .dimmed
    }

    private func choiceButton(index: Int, text: String) -> some View {
        let state = state(of: index)
        let letter = Self.letters[index]
        return Button {
            guard session.answer(index) != nil else { return }
            // VoiceOver reads the feedback block (verdict, right answer,
            // explanation) once focus lands on it.
            moveFocus(to: .feedback)
        } label: {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Text(letter)
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                Text(BankText.attributed(text))
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch state {
                case .correct:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NotoTheme.Colors.success)
                        .accessibilityHidden(true)
                case .wrongChosen:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NotoTheme.Colors.danger)
                        .accessibilityHidden(true)
                case .idle, .dimmed:
                    EmptyView()
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget, alignment: .leading)
            .background(background(for: state))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: NotoTheme.Radius.md)
                    .stroke(border(for: state), lineWidth: state == .idle || state == .dimmed ? 1 : 2)
            )
            .opacity(state == .dimmed ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Locked once answered: VoiceOver says so instead of offering
        // buttons that silently ignore taps.
        .disabled(state != .idle)
        .accessibilityLabel("Réponse \(letter) : \(BankText.plain(text))")
        .accessibilityValue(accessibilityValue(for: state))
        .accessibilityHint(state == .idle ? "Touche deux fois pour choisir cette réponse" : "")
    }

    private func background(for state: ChoiceState) -> Color {
        switch state {
        case .correct: NotoTheme.Colors.success.opacity(0.12)
        case .wrongChosen: NotoTheme.Colors.danger.opacity(0.10)
        case .idle, .dimmed: NotoTheme.Colors.surface
        }
    }

    private func border(for state: ChoiceState) -> Color {
        switch state {
        case .correct: NotoTheme.Colors.success
        case .wrongChosen: NotoTheme.Colors.danger
        case .idle, .dimmed: NotoTheme.Colors.border
        }
    }

    private func accessibilityValue(for state: ChoiceState) -> String {
        switch state {
        case .idle, .dimmed: ""
        case .correct: "Bonne réponse"
        case .wrongChosen: "Ta réponse, pas la bonne"
        }
    }

    // MARK: Feedback

    private func feedback(chosen: Int) -> some View {
        let correct = chosen == question.answerIndex
        let answer = question.choices[question.answerIndex]
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Label(correct ? "Bien joué !" : "Pas tout à fait…",
                  systemImage: correct ? "hand.thumbsup.fill" : "lightbulb.fill")
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            if !correct {
                Text("La bonne réponse : \(BankText.plain(answer))")
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }
            if let explanation = question.explanation, !explanation.isEmpty {
                Text(BankText.attributed(explanation))
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .signalCard(correct ? .positive : .info)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Quiz") {
    let child = PreviewData.revisionChild
    return QuizView(child: child, seed: 42)
        .withPreviewData()
}

#Preview("Quiz — banque vide") {
    let container = PreviewData.emptyBankContainer
    let child = try! container.mainContext.fetch(FetchDescriptor<Child>()).first!
    return QuizView(child: child)
        .modelContainer(container)
}
