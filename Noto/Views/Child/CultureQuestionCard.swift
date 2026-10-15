import SwiftUI

/// « La question culture du jour » on the child home: one Keskonfé question,
/// answered once, then the feedback and the explanation. Optional (hidden
/// when offline or when there is no lot) and reward-free: no minute, no XP
/// (`DailyCultureQuestion`). Child mode, tutoiement.
struct CultureQuestionCard: View {
    let question: DailyCultureQuestion
    let onAnswer: (Int) -> Void

    private static let letters = ["A", "B", "C", "D"]
    /// VoiceOver moves to the verdict once answered, as in `QuizView`.
    @AccessibilityFocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack(spacing: NotoTheme.Spacing.xs) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(NotoTheme.Colors.warning)
                    .accessibilityHidden(true)
                Text("Juste pour le plaisir")
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            Text(question.quiz.question)
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: NotoTheme.Spacing.xs) {
                ForEach(Array(question.quiz.choices.enumerated()), id: \.offset) { index, choice in
                    choiceButton(index: index, text: choice)
                }
            }

            if question.isAnswered {
                feedback
                    .accessibilityFocused($feedbackFocused)
            }
        }
        .onChange(of: question.answeredIndex) { _, answered in
            if answered != nil { feedbackFocused = true }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    private func choiceButton(index: Int, text: String) -> some View {
        let state = Self.choiceState(index: index, question: question)
        return Button {
            onAnswer(index)
        } label: {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Text(Self.letters[index])
                    .font(ChildStyle.caption.weight(.semibold))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch state {
                case .right:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NotoTheme.Colors.success)
                        .accessibilityHidden(true)
                case .wrong:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NotoTheme.Colors.danger)
                        .accessibilityHidden(true)
                case .neutral:
                    EmptyView()
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(state == .neutral ? NotoTheme.Colors.border
                            : (state == .right ? NotoTheme.Colors.success : NotoTheme.Colors.danger),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Answered once (the store ignores a second choice); not `.disabled`,
        // which would dim the right / wrong marks.
        .allowsHitTesting(!question.isAnswered)
        .accessibilityLabel("Réponse \(Self.letters[index]) : \(text)")
        .accessibilityValue(Self.accessibilityValue(state))
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            Text(Self.feedbackTitle(for: question))
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            if let explanation = question.quiz.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pure copy / state

    enum ChoiceState: Equatable { case neutral, right, wrong }

    static func choiceState(index: Int, question: DailyCultureQuestion) -> ChoiceState {
        guard let answered = question.answeredIndex else { return .neutral }
        if index == question.quiz.answerIndex { return .right }
        return index == answered ? .wrong : .neutral
    }

    static func feedbackTitle(for question: DailyCultureQuestion) -> String {
        if question.answeredCorrectly { return "Bonne réponse, bravo !" }
        let right = question.quiz.choices.indices.contains(question.quiz.answerIndex)
            ? question.quiz.choices[question.quiz.answerIndex] : ""
        return "Pas tout à fait : la bonne réponse était « \(right) »."
    }

    static func accessibilityValue(_ state: ChoiceState) -> String {
        switch state {
        case .neutral: ""
        case .right: "Bonne réponse"
        case .wrong: "Ta réponse, incorrecte"
        }
    }
}

#Preview("Question du jour") {
    CultureQuestionCard(
        question: DailyCultureQuestion(
            dayKey: "2026-10-15", lotDate: "2026-10-15",
            quiz: CultureLotQuizDto(
                id: UUID(), domain: "livres", question: "Qui a écrit « Vingt mille lieues sous les mers » ?",
                choices: ["Jules Verne", "Victor Hugo", "Alexandre Dumas", "Émile Zola"], answerIndex: 0,
                explanation: "Jules Verne publie ce roman en 1869-1870.", tone: "histoire"),
            answeredIndex: 2),
        onAnswer: { _ in }
    )
    .padding()
}
