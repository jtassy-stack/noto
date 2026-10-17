import SwiftUI

/// Culture G quiz, 10 Koi questions in a row (`CultureQuizDraw`), for the
/// parent (Découvrir, vouvoiement) or the child (child home, tutoiement,
/// child-filtered pool). Reward-free: no minute, no XP, no `QuizAttempt`.
struct CultureQuizView: View {
    let audience: CultureQuizAudience

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var questions: [CultureLotQuizDto] = []
    @State private var index = 0
    @State private var answers: [Int] = []
    @AccessibilityFocusState private var feedbackFocused: Bool

    private let poolStore = CultureQuizPoolStore()
    private let seenStore = CultureQuizSeenStore()
    private static let letters = ["A", "B", "C", "D"]

    enum Phase: Equatable { case loading, empty, playing, finished }

    private var copy: CultureQuizCopy { CultureQuizCopy(audience: audience) }
    private var isChild: Bool { audience.isChild }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView(copy.loading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView(copy.emptyTitle, systemImage: "lightbulb",
                                           description: Text(copy.emptyMessage))
                case .playing:
                    if questions.indices.contains(index) {
                        ScrollView { questionScreen(questions[index]) }
                    }
                case .finished:
                    resultScreen
                }
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Culture G")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task { await start() }
    }

    // MARK: - Screens

    private func questionScreen(_ quiz: CultureLotQuizDto) -> some View {
        let answered = answers.count > index ? answers[index] : nil
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
            HStack {
                Text("Question \(index + 1) sur \(questions.count)")
                    .font(captionFont)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Spacer()
                Text(CultureQuizCopy.domainLabel(quiz.domain))
                    .font(captionFont)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            Text(quiz.question)
                .font(isChild ? ChildStyle.question : NotoTheme.Typography.title)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: NotoTheme.Spacing.xs) {
                ForEach(Array(quiz.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                    choiceButton(quiz: quiz, index: choiceIndex, text: choice, answered: answered)
                }
            }

            if let answered {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    Text(copy.feedbackTitle(quiz: quiz, answered: answered))
                        .font(headlineFont)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    if let explanation = quiz.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(bodyFont)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityFocused($feedbackFocused)

                Button {
                    next()
                } label: {
                    Text(index + 1 < questions.count ? "Question suivante" : "Voir le score")
                        .font(headlineFont)
                        .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceButton(quiz: CultureLotQuizDto, index choiceIndex: Int, text: String,
                              answered: Int?) -> some View {
        let state = CultureQuizCopy.choiceState(index: choiceIndex, answerIndex: quiz.answerIndex, answered: answered)
        return Button {
            answer(choiceIndex)
        } label: {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Text(Self.letters[choiceIndex])
                    .font(captionFont.weight(.semibold))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(bodyFont)
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
        // Answered once; not `.disabled`, which would dim the marks.
        .allowsHitTesting(answered == nil)
        .accessibilityLabel("Réponse \(Self.letters[choiceIndex]) : \(text)")
        .accessibilityValue(copy.accessibilityValue(state))
    }

    private var resultScreen: some View {
        let score = CultureQuizCopy.score(questions: questions, answers: answers)
        return VStack(spacing: NotoTheme.Spacing.md) {
            Spacer()
            Text("\(score) / \(questions.count)")
                .font(isChild ? ChildStyle.figure : NotoTheme.Typography.dataLarge)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text(copy.resultMessage(score: score, total: questions.count))
                .font(bodyFont)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await start() }
            } label: {
                Text("Nouvelle série")
                    .font(headlineFont)
                    .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(NotoTheme.Spacing.md)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Fonts

    private var captionFont: Font { isChild ? ChildStyle.caption : NotoTheme.Typography.caption }
    private var bodyFont: Font { isChild ? ChildStyle.body : NotoTheme.Typography.body }
    private var headlineFont: Font { isChild ? ChildStyle.headline : NotoTheme.Typography.headline }

    // MARK: - Flow

    /// Draws from the local pool at once when it holds a full session, and
    /// refreshes it (new lots, backfill) before drawing otherwise.
    private func start() async {
        phase = .loading
        index = 0
        answers = []
        let calendar = Calendar.current
        let today = CalendarDay(Date(), calendar: calendar).key
        let seen = seenStore.seen(for: audience)
        var rng = SystemRandomNumberGenerator()

        var drawn = CultureQuizDraw.draw(from: poolStore.load().entries, audience: audience, seen: seen,
                                         today: today, calendar: calendar, using: &rng)
        if drawn.count < CultureQuizDraw.questionCount, !ProcessInfo.processInfo.isRunningForPreviews {
            let pool = await poolStore.refresh(client: QuizAPIClient(), now: Date(), calendar: calendar)
            drawn = CultureQuizDraw.draw(from: pool, audience: audience, seen: seen, today: today,
                                         calendar: calendar, using: &rng)
        } else if !ProcessInfo.processInfo.isRunningForPreviews {
            // Enough to play now; top the pool up for the next session.
            Task { await poolStore.refresh(client: QuizAPIClient(), now: Date(), calendar: calendar) }
        }
        questions = drawn
        phase = drawn.isEmpty ? .empty : .playing
    }

    private func answer(_ choice: Int) {
        guard answers.count == index, questions.indices.contains(index) else { return }
        answers.append(choice)
        seenStore.markSeen([questions[index].id], for: audience)
        feedbackFocused = true
    }

    private func next() {
        if index + 1 < questions.count {
            index += 1
        } else {
            phase = .finished
        }
    }
}

// MARK: - Copy

/// Every string of the culture quiz, per audience: vouvoiement for the parent,
/// tutoiement for the child (CLAUDE.md).
struct CultureQuizCopy: Equatable {
    let audience: CultureQuizAudience

    private var isChild: Bool { audience.isChild }

    var loading: String { "Préparation des questions…" }
    var emptyTitle: String { "Pas de questions pour l'instant" }
    var emptyMessage: String {
        isChild ? "Reviens plus tard, de nouvelles questions arrivent chaque jour."
            : "Vérifiez votre connexion : de nouvelles questions arrivent chaque jour."
    }

    func feedbackTitle(quiz: CultureLotQuizDto, answered: Int) -> String {
        if answered == quiz.answerIndex { return isChild ? "Bonne réponse, bravo !" : "Bonne réponse !" }
        let right = quiz.choices.indices.contains(quiz.answerIndex) ? quiz.choices[quiz.answerIndex] : ""
        return "Pas tout à fait : la bonne réponse était « \(right) »."
    }

    func resultMessage(score: Int, total: Int) -> String {
        let answers = score == 1 ? "bonne réponse" : "bonnes réponses"
        let subject = isChild ? "Tu as" : "Vous avez"
        let line = "\(subject) \(score) \(answers) sur \(total)."
        guard total > 0 else { return line }
        let ratio = Double(score) / Double(total)
        if ratio >= 0.8 { return line + (isChild ? " Impressionnant !" : " Belle culture générale !") }
        if ratio >= 0.5 { return line + " Pas mal du tout." }
        return line + (isChild ? " Retente ta chance, tu vas progresser !" : " Une autre série ?")
    }

    func accessibilityValue(_ state: CultureQuizCopy.ChoiceState) -> String {
        switch state {
        case .neutral: ""
        case .right: "Bonne réponse"
        case .wrong: isChild ? "Ta réponse, incorrecte" : "Votre réponse, incorrecte"
        }
    }

    enum ChoiceState: Equatable { case neutral, right, wrong }

    static func choiceState(index: Int, answerIndex: Int, answered: Int?) -> ChoiceState {
        guard let answered else { return .neutral }
        if index == answerIndex { return .right }
        return index == answered ? .wrong : .neutral
    }

    static func score(questions: [CultureLotQuizDto], answers: [Int]) -> Int {
        zip(questions, answers).filter { $0.answerIndex == $1 }.count
    }

    /// French label of a Koi domain (Keskonfé culture or news domain).
    static func domainLabel(_ domain: String) -> String {
        switch domain {
        case "films": "Cinéma"
        case "series": "Séries"
        case "animes": "Animés"
        case "livres": "Livres"
        case "musique": "Musique"
        case "podcasts": "Podcasts"
        case "spectacles": "Spectacles"
        case "expos": "Expositions"
        case "jeux": "Jeux vidéo"
        case "politique": "Politique"
        case "international": "International"
        case "societe": "Société"
        case "economie": "Économie"
        case "sante": "Santé"
        case "environnement": "Environnement"
        case "sciences_tech": "Sciences et tech"
        case "sport": "Sport"
        case "culture": "Culture"
        default: "Culture G"
        }
    }
}

#Preview("Parent") {
    CultureQuizView(audience: .parent)
}
