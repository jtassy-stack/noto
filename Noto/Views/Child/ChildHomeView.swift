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
struct ChildHomeView: View {
    @Query private var families: [Family]
    @Query private var attempts: [QuizAttempt]
    @Query(filter: #Predicate<QuizItem> { $0.reviewed == true }) private var reviewedItems: [QuizItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var screenTimeManager = ScreenTimeManager.shared
    @State private var showParentGate = false
    @State private var gateApproved = false
    @State private var showSettings = false
    @State private var showQuiz = false

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
            .fullScreenCover(isPresented: $showQuiz) {
                if let child {
                    QuizView(child: child)
                }
            }
        }
        .onAppear {
            screenTimeManager.refresh()
        }
        .task(id: child?.persistentModelID) {
            await syncQuestionBank()
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
        let minutes = QuizStreak.minutesEarnedToday(attempts: snapshots, now: Date(), calendar: .current)
        let streak = QuizStreak.current(attempts: snapshots, now: Date(), calendar: .current)
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
                streakCard(days: streak)
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
        }
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

    private func streakCard(days: Int) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
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
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days == 0
            ? "Ta série : pas encore commencée"
            : "Ta série : \(days) \(days == 1 ? "jour" : "jours d'affilée")")
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
