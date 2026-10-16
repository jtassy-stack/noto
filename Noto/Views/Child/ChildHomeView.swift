import OSLog
import SwiftUI
import SwiftData

private let logger = Logger(subsystem: "com.pmf.noto", category: "ChildHomeView")

/// Child-facing home for devices set to `DeviceMode.child`: cagnotte, série,
/// « Réviser » entry, next contrôle, today's schedule and the current Screen
/// Time status, read-only. Parent controls (restrictions, thresholds,
/// class-lock setup) stay in `ScreenTimeView`/Settings, behind the parent
/// gate. Every string here addresses the child (tutoiement, CLAUDE.md
/// exception for `DeviceMode.child`).
///
/// The cagnotte shows minutes earned from `QuizAttempt` only: crediting and
/// unlocking Screen Time is 3.4, so nothing here promises an unlock.
///
/// Gamification (3.6): the série with its monthly jokers, the « Mes badges »
/// link (earned badges only), the optional culture question of the day
/// (reward-free) and, only when the parent turned it on, the family weekly
/// challenge.
struct ChildHomeView: View {
    @Query private var families: [Family]
    @Query private var attempts: [QuizAttempt]
    @Query private var jokerRows: [StreakJoker]
    @Query(filter: #Predicate<QuizItem> { $0.reviewed == true }) private var reviewedItems: [QuizItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var screenTimeManager = ScreenTimeManager.shared
    @State private var showParentGate = false
    @State private var gateApproved = false
    @State private var showSettings = false
    @State private var showQuiz = false
    @State private var cultureQuestion: DailyCultureQuestion?
    /// Device day the home was last refreshed for. Bumped on return to the
    /// foreground and at midnight, so a home left mounted overnight reloads
    /// the culture question and re-renders the série for the new day.
    @State private var dayKey = CalendarDay(Date(), calendar: .current).key
    private let cultureStore = DailyCultureQuestionStore()

    private var child: Child? {
        guard let linkedID = ScreenTimeEventStore.loadLinkedChildID() else {
            return families.first?.children.first
        }
        return families.first?.children.first(where: { "\($0.id)" == linkedID }) ?? families.first?.children.first
    }

    private var todaysLessons: [ScheduleEntry] {
        guard let child else { return [] }
        return child.schedule
            .filter { Calendar.current.isDateInToday($0.start) && !$0.cancelled }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    Text(greeting)
                        .font(ChildStyle.greeting)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)

                    if let child {
                        revisionSection(for: child)
                    }
                    if let cultureQuestion {
                        cultureSection(cultureQuestion)
                    }
                    scheduleSection
                    screenTimeStatusSection
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // No PIN configured yet (e.g. upgraded from before
                        // this feature existed) — fail open rather than
                        // permanently locking Settings out of reach.
                        if ParentGateService.isConfigured {
                            showParentGate = true
                        } else {
                            showSettings = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Réglages — protégé par code parent")
                }
            }
            // Réglages (restrictions, déconnexion des comptes, etc.) est un
            // écran parent — un enfant qui tient ce téléphone ne doit pas
            // pouvoir désactiver son propre contrôle parental d'un tap.
            .sheet(isPresented: $showParentGate, onDismiss: {
                if gateApproved {
                    gateApproved = false
                    showSettings = true
                }
            }) {
                ParentGateView(mode: .verify) { success in gateApproved = success }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $showQuiz, onDismiss: { recordDueJokers() }) {
                if let child {
                    QuizView(child: child)
                }
            }
        }
        .onAppear {
            screenTimeManager.refresh()
        }
        .task(id: child?.persistentModelID) {
            recordDueJokers()
            await syncQuestionBank()
        }
        .task(id: dayKey) {
            recordDueJokers()
            await loadCultureQuestion()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshDay() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshDay()
        }
    }

    // MARK: - Révisions

    /// Opportunistic refresh of the celyn programme bank for the child's
    /// level (throttled to once per 12 h per level by `QuizBankStore`). Only
    /// questions come down; nothing about the child goes up. Failures keep
    /// the local bank and are retried on a later appearance.
    ///
    /// The bundled snapshot is seeded first when the level has no celyn item
    /// yet, so « Réviser » works offline on first launch; a seed failure never
    /// skips the network sync.
    private func syncQuestionBank() async {
        guard let child, !ProcessInfo.processInfo.isRunningForPreviews else { return }
        let store = QuizBankStore(modelContext: modelContext)
        do {
            try store.seedBundledIfNeeded(level: child.grade)
        } catch {
            logger.info("Bundled bank seed skipped: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try await store.sync(child: child)
        } catch {
            logger.info("Bank sync skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Safety net for the joker save done by `QuizSession.finish`: persists
    /// the gap jokers once today has a passed quiz (idempotent; pending, and
    /// nothing saved, before that). Runs on appear, on a new day and when the
    /// quiz cover closes.
    private func recordDueJokers() {
        guard let child, !ProcessInfo.processInfo.isRunningForPreviews else { return }
        GamificationStore.recordDueJokers(for: child, in: modelContext, now: Date(), calendar: .current)
    }

    /// Re-keys the day-bound tasks when the device day changed.
    private func refreshDay() {
        let today = CalendarDay(Date(), calendar: .current).key
        if today != dayKey { dayKey = today }
    }

    /// Today's culture question: cache, else one anonymous GET (only
    /// `app=keskonfe`). Nil (no card) when offline or without a lot. A
    /// question cached for another day is dropped first (no stale card).
    private func loadCultureQuestion() async {
        guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
        // General-audience pool (no kid-safe flag yet): only when a parent opted in.
        guard CultureQuestionSettings.isEnabled() else { cultureQuestion = nil; return }
        if let shown = cultureQuestion, shown.dayKey != dayKey { cultureQuestion = nil }
        cultureQuestion = await cultureStore.questionOfTheDay(client: QuizAPIClient(), now: Date(),
                                                              calendar: .current)
    }

    private func jokerDays(for child: Child) -> [CalendarDay] {
        jokerRows
            .filter { $0.child?.persistentModelID == child.persistentModelID }
            .compactMap(\.day)
    }

    private func attemptSnapshots(for child: Child) -> [AttemptSnapshot] {
        attempts
            .filter { $0.child?.persistentModelID == child.persistentModelID }
            .map { AttemptSnapshot($0) }
    }

    /// Same predicate as the quiz draw (`QuizSession.availableItems`), so the
    /// home never offers « Réviser » on a quiz that would open empty. The
    /// `@Query` is read so the view refreshes when the bank changes.
    private func availableQuestions(for child: Child) -> Int {
        guard !reviewedItems.isEmpty else { return 0 }
        return QuizSession.availableCount(for: child, in: modelContext)
    }

    /// Subject of tomorrow's contrôle when `ExamKeywordDetector` sees one.
    private func examTomorrow(for child: Child) -> (found: Bool, subject: String?) {
        let calendar = Calendar.current
        let now = Date()
        let homework = child.homework.map { HomeworkSnapshot($0, calendar: calendar) }
        let schedule = child.schedule.map { ScheduleSnapshot($0) }
        guard ExamKeywordDetector.hasExamTomorrow(homework: homework, schedule: schedule,
                                                  now: now, calendar: calendar) else { return (false, nil) }
        let tomorrow = calendar.quizStartOfDay(addingDays: 1, to: now)
        let subject = homework.first {
            !$0.done && calendar.isDate($0.dueDate, inSameDayAs: tomorrow)
                && ExamKeywordDetector.matches($0.descriptionText)
        }?.subject
        return (true, subject)
    }

    @ViewBuilder
    private func revisionSection(for child: Child) -> some View {
        let snapshots = attemptSnapshots(for: child)
        let now = Date()
        let minutes = QuizStreak.minutesEarnedToday(attempts: snapshots, now: now, calendar: .current)
        let jokers = jokerDays(for: child)
        let streak = Gamification.streak(attempts: snapshots, jokers: jokers, now: now, calendar: .current)
        let badgeCount = Gamification.badges(
            attempts: snapshots, masteries: child.notionMasteries.map { MasterySnapshot($0) },
            jokers: jokers + streak.newJokers, level: child.grade, specialties: child.specialties,
            curriculum: CurriculumSnapshot.bundled, calendar: .current
        ).count
        let exam = examTomorrow(for: child)

        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Révisions")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            // Side by side, stacked at accessibility text sizes (half-width
            // cards would truncate the figures).
            let cardsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: NotoTheme.Spacing.cardGap))
                : AnyLayout(HStackLayout(alignment: .top, spacing: NotoTheme.Spacing.cardGap))
            cardsLayout {
                cagnotteCard(minutes: minutes)
                streakCard(streak)
            }

            if FamilyChallengeSettings.isEnabled() {
                familyChallengeCard(
                    passed: Gamification.passedQuizzesThisWeek(attempts: snapshots, now: now, calendar: .current))
            }

            if exam.found {
                examCard(subject: exam.subject)
            }

            if availableQuestions(for: child) > 0 {
                ChildPrimaryButton(title: "Réviser (3 min)", systemImage: "sparkles") {
                    showQuiz = true
                }
                .accessibilityHint("Lance un petit quiz de quelques questions")
            } else {
                ChildEmptyState(systemImage: "tray",
                                title: "Les questions arrivent bientôt",
                                message: "On prépare des questions pour ta classe. Reviens un peu plus tard !")
            }

            NavigationLink {
                SubjectPathView(child: child)
            } label: {
                HStack {
                    Label("Mon parcours", systemImage: "map")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(ChildStyle.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .frame(minHeight: ChildStyle.minTapTarget)
                .notoCard()
            }
            .accessibilityHint("Tes thèmes de l'année et ta progression")

            // Earned badges only: the link appears with the first one.
            if badgeCount > 0 {
                NavigationLink {
                    BadgesView(child: child)
                } label: {
                    HStack {
                        Label("Mes badges", systemImage: "rosette")
                            .font(ChildStyle.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Spacer()
                        Text("\(badgeCount)")
                            .font(ChildStyle.caption.monospacedDigit())
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(ChildStyle.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .frame(minHeight: ChildStyle.minTapTarget)
                    .notoCard()
                }
                .accessibilityLabel("Mes badges : \(badgeCount) \(badgeCount == 1 ? "badge gagné" : "badges gagnés")")
            }
        }
    }

    private func cultureSection(_ question: DailyCultureQuestion) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Question culture du jour")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)
            CultureQuestionCard(question: question) { choice in
                if let updated = cultureStore.recordAnswer(choice, now: Date(), calendar: .current) {
                    cultureQuestion = updated
                } else if cultureStore.cached(now: Date(), calendar: .current) == nil {
                    // Yesterday's card after midnight: drop it and load today's.
                    cultureQuestion = nil
                    refreshDay()
                }
            }
        }
    }

    private func familyChallengeCard(passed: Int) -> some View {
        let goal = FamilyChallengeSettings.weeklyGoal
        return HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(NotoTheme.Colors.info)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Défi de la semaine en famille")
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(Self.familyChallengeText(passed: passed, goal: goal))
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .combine)
    }

    static func familyChallengeText(passed: Int, goal: Int) -> String {
        passed >= goal
            ? "Défi réussi : \(passed) quiz réussis cette semaine !"
            : "\(min(passed, goal)) quiz réussis sur \(goal) cette semaine."
    }

    private func cagnotteCard(minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            Text("Ta cagnotte")
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            Text("\(minutes) min")
                .font(ChildStyle.figure)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("gagnées aujourd'hui")
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ta cagnotte : \(minutes) minutes gagnées aujourd'hui")
    }

    private func streakCard(_ streak: StreakStatus) -> some View {
        let days = streak.days
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            Text("Ta série")
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: NotoTheme.Spacing.xs) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(days > 0 ? NotoTheme.Colors.warning : NotoTheme.Colors.textTertiary)
                    .accessibilityHidden(true)
                Text("\(days)")
                    .font(ChildStyle.figure)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Text(days == 0 ? "lance-la avec un quiz" : (days == 1 ? "jour" : "jours d'affilée"))
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            if let jokerText = Self.jokerText(streak) {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .accessibilityHidden(true)
                    Text(jokerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.streakAccessibilityLabel(streak))
    }

    /// Jokers line, child wording: only the positive note when a saved joker
    /// protected the série, nothing otherwise. The stock is never shown (no
    /// « plus de joker », no scarcity cue: jokers work quietly) and pending
    /// jokers (not saved until a quiz is passed today) say nothing either.
    static func jokerText(_ streak: StreakStatus) -> String? {
        guard streak.days > 0, streak.protectedByJoker, streak.newJokers.isEmpty else { return nil }
        return "Un joker a protégé ta série."
    }

    static func streakAccessibilityLabel(_ streak: StreakStatus) -> String {
        let days = streak.days
        let head = days == 0
            ? "Ta série : pas encore commencée."
            : "Ta série : \(days) \(days == 1 ? "jour" : "jours d'affilée")."
        return jokerText(streak).map { "\(head) \($0)" } ?? head
    }

    private func examCard(subject: String?) -> some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "list.clipboard")
                .foregroundStyle(NotoTheme.Colors.info)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.map { "Contrôle demain : \($0.capitalized)" } ?? "Contrôle demain")
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text("Un petit quiz ce soir pour t'échauffer ?")
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .signalCard(.info)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        guard let child else { return "Bonjour" }
        return "Salut \(child.firstName)"
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Aujourd'hui")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            if todaysLessons.isEmpty {
                Text("Pas de cours aujourd'hui.")
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(NotoTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notoCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(todaysLessons.enumerated()), id: \.element.id) { index, lesson in
                        if index > 0 { SettingsDivider() }
                        HStack(spacing: NotoTheme.Spacing.md) {
                            Text(lesson.start.formatted(.dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))))
                                .font(ChildStyle.headline.monospacedDigit())
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .frame(minWidth: 48, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.subject)
                                    .font(ChildStyle.body)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                if let room = lesson.room {
                                    Text(room)
                                        .font(ChildStyle.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 12)
                    }
                }
                .notoCard()
            }
        }
    }

    private var screenTimeStatusSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Temps d'écran")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            HStack {
                Image(systemName: screenTimeManager.isAuthorized ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(screenTimeManager.isAuthorized ? NotoTheme.Colors.success : NotoTheme.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(screenTimeManager.isAuthorized ? "Contrôle actif" : "Contrôle non configuré")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    if ScreenTimeEventStore.isClassLockEnabled() {
                        Text("Verrouillage pendant les cours activé")
                            .font(ChildStyle.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(NotoTheme.Spacing.md)
            .notoCard()
        }
    }
}

#Preview("Accueil enfant") {
    ChildHomeView()
        .withPreviewData()
}
