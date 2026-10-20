import OSLog
import SwiftUI
import SwiftData

private let logger = Logger(subsystem: "com.pmf.noto", category: "ChildHomeView")

/// The child app's tabs (`DeviceMode.child`).
enum ChildTab: Hashable {
    case today, courses, revise, path, me
}

/// Child-facing app for devices set to `DeviceMode.child`, in five tabs:
/// - « Aujourd'hui » (`ChildTodayView`): cagnotte, série, tomorrow's
///   contrôle and the school day, lessons with their homework and the class
///   lock, ending on the quiz of the day.
/// - « Mes cours » (`ChildCoursesView`): all homework to do, the timetable
///   and the grades (hidden when the parent turns « Afficher les notes » off).
/// - « Réviser » (`ChildReviseView`): the quiz of the day and what it is made
///   of, the themes taught in class now, and the reward-free culture corner.
/// - « Parcours » (`SubjectPathView`): themes, XP and levels per subject.
/// - « Moi » (`ChildMeView`): the série month, badges, the family challenge
///   and Réglages behind the parent PIN.
///
/// This container owns what the tabs share: the linked child, the quiz
/// cover, the parent gate, the joker / bank / culture refreshes and the
/// reward status. Parent controls (restrictions, thresholds, class-lock
/// setup) stay in `ScreenTimeView`/Settings, behind the parent gate. Every
/// string addresses the child (tutoiement, CLAUDE.md exception for
/// `DeviceMode.child`).
///
/// The cagnotte shows minutes earned from `QuizAttempt`. Since 3.4 a line
/// under it says what the minutes do (« Tes N min sont débloquées », « Tes
/// minutes t'attendent après les cours »…), read from the reward ledger
/// (`RewardUnlockService.status`), and only when Screen Time is authorized
/// with watched apps; otherwise the neutral wording stays.
///
/// « Vision enfant »: the parent app opens this same view with
/// `previewChild` to show a parent what that child sees. It is read only:
/// nothing that writes the child's progress runs (quiz, culture answer,
/// jokers), the reward status stays neutral and the class lock is not
/// claimed (both describe the device the child plays on), and every action
/// shows `previewNotice` instead. Only the question bank refresh runs, as on
/// any device (questions come down, nothing goes up). Quiz, série and badges
/// are empty unless the child's phone is linked (family sync, phase 9.3).
struct ChildHomeView: View {
    /// The child the parent is looking at; nil on a child device.
    var previewChild: Child? = nil

    /// Explicit: the private wrapped properties make the synthesized
    /// memberwise init private, so `ParentWeekSection` could not reach it.
    init(previewChild: Child? = nil) {
        self.previewChild = previewChild
    }

    @Query private var families: [Family]
    @Query private var attempts: [QuizAttempt]
    @Query private var jokerRows: [StreakJoker]
    @Query(filter: #Predicate<QuizItem> { $0.reviewed == true }) private var reviewedItems: [QuizItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var screenTimeManager = ScreenTimeManager.shared
    @State private var tab: ChildTab = .today
    /// Subject shown by « Parcours », set when « Réviser » opens a subject.
    @State private var pathSubject: String?
    @State private var showParentGate = false
    @State private var gateApproved = false
    @State private var showSettings = false
    @State private var showQuiz = false
    /// Subject or theme of the quiz to open; nil = the quiz of the day.
    @State private var quizFocus: QuizFocus?
    @State private var cultureQuestion: DailyCultureQuestion?
    @State private var cultureQuizEnabled = false
    @State private var gradesVisible = ChildGradesSettings.isVisible()
    @State private var rewardStatus: RewardStatus = .neutral
    /// Device day the home was last refreshed for. Bumped on return to the
    /// foreground and at midnight, so a home left mounted overnight reloads
    /// the culture question and re-renders the série for the new day.
    @State private var dayKey = CalendarDay(Date(), calendar: .current).key
    @State private var showPreviewNotice = false
    @Environment(\.dismiss) private var dismiss
    private let cultureStore = DailyCultureQuestionStore()

    private var isPreview: Bool { previewChild != nil }

    private var child: Child? {
        if let previewChild { return previewChild }
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
        let child = self.child
        let now = Date()
        let snapshots = child.map { attemptSnapshots(for: $0) } ?? []
        let jokers = child.map { jokerDays(for: $0) } ?? []
        let streak = Gamification.streak(attempts: snapshots, jokers: jokers, now: now, calendar: .current)
        let canQuiz = child.map { availableQuestions(for: $0) > 0 } ?? false

        TabView(selection: $tab) {
            NavigationStack {
                ChildTodayView(
                    child: child,
                    lessons: todaysLessons,
                    minutes: QuizStreak.minutesEarnedToday(attempts: snapshots, now: now, calendar: .current),
                    streak: streak,
                    rewardStatus: rewardStatus,
                    exam: child.flatMap { examTomorrow(for: $0) },
                    examBonus: Self.examBonusMinutes(RewardConfigStore.load()),
                    classLockActive: !isPreview && screenTimeManager.isAuthorized
                        && ScreenTimeEventStore.isClassLockEnabled(),
                    canQuiz: canQuiz,
                    onStartQuiz: { startQuiz(nil) }
                )
            }
            .tabItem { Label("Aujourd'hui", systemImage: "calendar") }
            .tag(ChildTab.today)

            NavigationStack {
                if let child {
                    ChildCoursesView(child: child, gradesVisible: gradesVisible)
                } else {
                    noChildState
                }
            }
            .tabItem { Label("Mes cours", systemImage: "book") }
            .tag(ChildTab.courses)

            NavigationStack {
                let plan = child.map { QuizSession.plan(for: $0, now: now) }
                ChildReviseView(
                    child: child,
                    plan: plan,
                    subjects: child.map { subjectChoices(for: $0, position: plan?.position ?? .empty) } ?? [],
                    canQuiz: canQuiz,
                    cultureQuestion: cultureQuestion,
                    cultureQuizEnabled: cultureQuizEnabled,
                    onStartQuiz: { startQuiz($0) },
                    onCultureAnswer: { answerCultureQuestion($0) },
                    onPreviewAction: isPreview ? { showPreviewNotice = true } : nil
                )
            }
            .tabItem { Label("Réviser", systemImage: "sparkles") }
            .tag(ChildTab.revise)

            NavigationStack {
                if let child {
                    SubjectPathView(child: child, selectedSubject: $pathSubject,
                                    onRevise: { startQuiz($0) })
                } else {
                    noChildState
                }
            }
            .tabItem { Label("Parcours", systemImage: "map") }
            .tag(ChildTab.path)

            NavigationStack {
                ChildMeView(
                    child: child,
                    attempts: snapshots,
                    jokers: jokers + streak.newJokers,
                    streak: streak,
                    familyChallengePassed: FamilyChallengeSettings.isEnabled()
                        ? Gamification.passedQuizzesThisWeek(attempts: snapshots, now: now, calendar: .current)
                        : nil,
                    onOpenSettings: { openSettings() }
                )
            }
            .tabItem { Label("Moi", systemImage: "person.crop.circle") }
            .tag(ChildTab.me)
        }
        .tint(ChildStyle.accent)
        // Vision enfant: the parent's bar above every tab.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let previewChild {
                ChildPreviewBanner(firstName: previewChild.firstName, linked: previewChild.receivesFamilySync,
                                   onClose: { dismiss() })
            }
        }
        .alert(ChildPreviewBanner.actionTitle, isPresented: $showPreviewNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ChildPreviewBanner.actionMessage(child?.firstName ?? "Votre enfant"))
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
        // The parent may have flipped « Culture générale » there: re-read
        // it now rather than at the next day change.
        .sheet(isPresented: $showSettings, onDismiss: {
            gradesVisible = ChildGradesSettings.isVisible()
            Task { await loadCultureQuestion() }
        }) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showQuiz, onDismiss: {
            recordDueJokers()
            refreshRewardStatus()
        }) {
            if let child {
                QuizView(child: child, focus: quizFocus)
            }
        }
        .onAppear {
            screenTimeManager.refresh()
            refreshRewardStatus()
            gradesVisible = ChildGradesSettings.isVisible()
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
            if phase == .active {
                refreshDay()
                refreshRewardStatus()
                // A resident app must still pick up questions celyn added
                // since launch (the store throttles itself per level).
                Task { await syncQuestionBank() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshDay()
        }
    }

    private var noChildState: some View {
        ScrollView {
            ChildEmptyState(systemImage: "person.crop.circle.badge.questionmark",
                            title: "Ton profil arrive bientôt",
                            message: "Demande à tes parents de relier ce téléphone à ton profil.")
                .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
    }

    /// No PIN configured yet (e.g. upgraded from before this feature
    /// existed): fail open rather than permanently locking Settings out of
    /// reach.
    private func openSettings() {
        if isPreview {
            showPreviewNotice = true
        } else if ParentGateService.isConfigured {
            showParentGate = true
        } else {
            showSettings = true
        }
    }

    private func startQuiz(_ focus: QuizFocus?) {
        guard !isPreview else { showPreviewNotice = true; return }
        quizFocus = focus
        showQuiz = true
    }

    /// The subjects « Réviser » offers: the child's programme subjects that
    /// have at least one question, each with the theme taught in class now.
    private func subjectChoices(for child: Child, position: ProgrammePosition) -> [ChildReviseView.SubjectChoice] {
        guard !reviewedItems.isEmpty else { return [] }
        let subjects = SubjectProgress.path(level: child.grade, specialties: child.specialties, masteries: [],
                                            curriculum: CurriculumSnapshot.bundled).map(\.subject)
        let counts = QuizSession.availableCounts(for: child, in: modelContext,
                                                 focuses: subjects.map { QuizFocus(subject: $0) })
        return zip(subjects, counts).compactMap { subject, count in
            guard count > 0 else { return nil }
            return ChildReviseView.SubjectChoice(
                subject: subject, inClass: position.position(forSubject: subject)?.current.first?.theme)
        }
    }

    private func answerCultureQuestion(_ choice: Int) {
        guard !isPreview else { showPreviewNotice = true; return }
        if let updated = cultureStore.recordAnswer(choice, now: Date(), calendar: .current) {
            cultureQuestion = updated
        } else if cultureStore.cached(now: Date(), calendar: .current) == nil {
            // Yesterday's card after midnight: drop it and load today's.
            cultureQuestion = nil
            refreshDay()
        }
    }

    // MARK: - Refreshes

    /// Opportunistic refresh of the celyn programme bank for the child's
    /// level (throttled to once per 12 h per level by `QuizBankStore`). Only
    /// questions come down; nothing about the child goes up. Failures keep
    /// the local bank and are retried on the next return to the foreground.
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
        guard let child, !isPreview, !ProcessInfo.processInfo.isRunningForPreviews else { return }
        GamificationStore.recordDueJokers(for: child, in: modelContext, now: Date(), calendar: .current)
    }

    /// Reward wording, re-read on appear, foreground and after a quiz (the
    /// extension updates the ledger in the background).
    private func refreshRewardStatus() {
        guard !isPreview, !ProcessInfo.processInfo.isRunningForPreviews else { return }
        rewardStatus = RewardUnlockService.status(schedule: child?.schedule ?? [])
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
        cultureQuizEnabled = CultureQuestionSettings.isEnabled()
        guard cultureQuizEnabled else { cultureQuestion = nil; return }
        if let shown = cultureQuestion, shown.dayKey != dayKey { cultureQuestion = nil }
        cultureQuestion = await cultureStore.questionOfTheDay(client: QuizAPIClient(), now: Date(),
                                                              calendar: .current)
    }

    // MARK: - Derived data

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
    /// app never offers a quiz that would open empty. The `@Query` is read so
    /// the view refreshes when the bank changes.
    private func availableQuestions(for child: Child) -> Int {
        guard !reviewedItems.isEmpty else { return 0 }
        return QuizSession.availableCount(for: child, in: modelContext)
    }

    /// Tomorrow's contrôle when `ExamKeywordDetector` sees one, with its
    /// subject when a homework row names it.
    private func examTomorrow(for child: Child) -> ExamTomorrow? {
        let calendar = Calendar.current
        let now = Date()
        let homework = child.homework.map { HomeworkSnapshot($0, calendar: calendar) }
        let schedule = child.schedule.map { ScheduleSnapshot($0) }
        guard ExamKeywordDetector.hasExamTomorrow(homework: homework, schedule: schedule,
                                                  now: now, calendar: calendar) else { return nil }
        let tomorrow = calendar.quizStartOfDay(addingDays: 1, to: now)
        let subject = homework.first {
            !$0.done && calendar.isDate($0.dueDate, inSameDayAs: tomorrow)
                && ExamKeywordDetector.matches($0.descriptionText)
        }?.subject
        return ExamTomorrow(subject: subject)
    }

    // MARK: - Copy (pure, tested)

    /// Exam-eve bonus the parent's rules grant, nil when turned off (the
    /// contrôle card then promises nothing).
    static func examBonusMinutes(_ config: RewardConfig) -> Int? {
        config.examEveBonusEnabled && config.examEveBonus > 0 ? config.examEveBonus : nil
    }

    static func familyChallengeText(passed: Int, goal: Int) -> String {
        passed >= goal
            ? "Défi réussi : \(passed) quiz réussis cette semaine !"
            : "\(min(passed, goal)) quiz réussis sur \(goal) cette semaine."
    }

    /// Child wording for the reward state, nil = keep the neutral cagnotte
    /// line only (no Screen Time setup, or nothing owed today).
    static func rewardStatusText(_ status: RewardStatus) -> (title: String, detail: String?)? {
        switch status {
        case .neutral:
            return nil
        case .unlocked(let minutes):
            return ("Tes \(minutes) min sont débloquées",
                    "Tes applis sont ouvertes, profites-en !")
        case .afterClass:
            return ("Tes minutes t'attendent après les cours", nil)
        case .waitingForBudget(let minutes):
            return ("Tes \(minutes) min t'attendent",
                    "Elles s'ajoutent quand ton temps d'écran du jour est fini.")
        }
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
}

/// Tomorrow's contrôle as the home shows it.
struct ExamTomorrow: Equatable, Sendable {
    /// Subject of the homework that announces it, when one does.
    let subject: String?
}

#Preview("App enfant") {
    ChildHomeView()
        .withPreviewData()
}

#Preview("Vision enfant (parent)") {
    PreviewChildHomeView()
        .withPreviewData()
}

/// Preview helper: the parent's « vision enfant » on the first child.
private struct PreviewChildHomeView: View {
    @Query private var families: [Family]
    var body: some View {
        if let child = families.first?.children.first {
            ChildHomeView(previewChild: child)
        }
    }
}
