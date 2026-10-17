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
                    // Also shown while the on-device model prepares homework
                    // questions (3.3, at most `QuizGenerator.defaultTimeout`).
                    ProgressView("On prépare tes questions…")
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
        // The parent's rules, read once per quiz from the app group.
        let config = RewardConfigStore.load()
        // 3.4: minutes earned go to the reward ledger, then unlock (or wait
        // in the reserve during a class block).
        let child = self.child
        let credit: @MainActor (Int, Date) -> Void = { minutes, date in
            RewardUnlockService.credit(minutes: minutes, at: date, schedule: child.schedule)
        }
        // 3.3: homework slots the bank cannot fill get an on-device question
        // (FoundationModels, iOS 26+ with Apple Intelligence), else the bank
        // fills them, silently. No network on this path.
        let generator = QuizGenerator()
        if let seed {
            session = await QuizSession.make(child: child, modelContext: modelContext, config: config, seed: seed,
                                             onMinutesEarned: credit, generator: generator)
        } else {
            session = await QuizSession.make(child: child, modelContext: modelContext, config: config,
                                             onMinutesEarned: credit, generator: generator)
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
                QuizQuestionScreen(session: session, question: question, copy: .child)
                    .id(question.id)
            }
        case .finished:
            if let result = session.result {
                QuizResultView(result: result,
                               onDone: { dismiss() },
                               onAnotherQuiz: {
                                   self.session = nil
                                   Task { await startSession() }
                               })
            }
        }
    }
}

/// Wording of `QuizQuestionScreen`: tutoiement for the child's quiz,
/// vouvoiement for the parent's (`ParentQuizView`).
struct QuizQuestionCopy: Sendable {
    let correct: String
    let incorrect: String
    let nextQuestion: String
    let seeResult: String
    let chosenWrong: String
    let choiceHint: String

    static let child = QuizQuestionCopy(
        correct: "Bien joué !", incorrect: "Pas tout à fait…", nextQuestion: "Question suivante",
        seeResult: "Voir mon résultat", chosenWrong: "Ta réponse, pas la bonne",
        choiceHint: "Touche deux fois pour choisir cette réponse"
    )

    static let parent = QuizQuestionCopy(
        correct: "Bonne réponse", incorrect: "Ce n'est pas la bonne réponse", nextQuestion: "Question suivante",
        seeResult: "Voir votre résultat", chosenWrong: "Votre réponse, pas la bonne",
        choiceHint: "Touchez deux fois pour choisir cette réponse"
    )
}

/// The current question, its choices and the feedback once answered. Shared
/// by the child's quiz and the parent's (`ParentQuizView`): same questions,
/// same screen, only the wording changes.
struct QuizQuestionScreen<Session: QuizPlaying>: View {
    let session: Session
    let question: QuizQuestion
    let copy: QuizQuestionCopy

    private static let letters = ["A", "B", "C", "D"]

    /// Bank text (reviewed) may carry inline Markdown; generated text is
    /// model output and is shown verbatim: no link can become tappable.
    private func display(_ raw: String) -> AttributedString {
        question.isGenerated ? AttributedString(raw) : BankText.attributed(raw)
    }

    private enum Focus: Hashable { case question, feedback }
    @AccessibilityFocusState private var focus: Focus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                header

                Text(display(question.question))
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
                    ChildPrimaryButton(title: session.isLastQuestion ? copy.seeResult : copy.nextQuestion,
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
                Text(display(text))
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
        .accessibilityHint(state == .idle ? copy.choiceHint : "")
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
        case .wrongChosen: copy.chosenWrong
        }
    }

    // MARK: Feedback

    private func feedback(chosen: Int) -> some View {
        let correct = chosen == question.answerIndex
        let answer = question.choices[question.answerIndex]
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Label(correct ? copy.correct : copy.incorrect,
                  systemImage: correct ? "hand.thumbsup.fill" : "lightbulb.fill")
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            if !correct {
                Text("La bonne réponse : \(BankText.plain(answer))")
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }
            if let explanation = question.explanation, !explanation.isEmpty {
                Text(display(explanation))
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
