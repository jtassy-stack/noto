import SwiftUI

/// « Aujourd'hui », the child app's first tab: the school day as the spine.
/// Cagnotte and série first, tomorrow's contrôle when there is one, then
/// « Ma journée »: today's lessons with the homework of each subject under
/// it, the class lock said plainly (never lifted by the cagnotte), and the
/// quiz of the day at the end, « après les cours, quand tu veux » (no fixed
/// time). Child mode, tutoiement.
struct ChildTodayView: View {
    let child: Child?
    let lessons: [ScheduleEntry]
    let minutes: Int
    let streak: StreakStatus
    let rewardStatus: RewardStatus
    let exam: ExamTomorrow?
    /// Exam-eve bonus minutes, nil when the parent turned it off.
    let examBonus: Int?
    /// Screen Time authorized and the class lock on.
    let classLockActive: Bool
    let canQuiz: Bool
    let onStartQuiz: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                header

                VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                    // Side by side, stacked at accessibility text sizes (half-width
                    // cards would truncate the figures).
                    let cardsLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: NotoTheme.Spacing.cardGap))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: NotoTheme.Spacing.cardGap))
                    cardsLayout {
                        cagnotteCard
                        streakCard
                    }
                    if let text = ChildHomeView.rewardStatusText(rewardStatus) {
                        rewardStatusCard(text)
                    }
                }

                if let exam {
                    examCard(exam)
                }

                daySection
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.dateLine(Date()))
                .font(ChildStyle.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            Text(child.map { "Salut \($0.firstName)" } ?? "Bonjour")
                .font(ChildStyle.greeting)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, NotoTheme.Spacing.sm)
    }

    // MARK: - Cagnotte & série

    private var cagnotteCard: some View {
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

    /// Amber is the série's colour only in the child app (« à revoir » is
    /// cobalt, an information, not a warning).
    private var streakCard: some View {
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
            if let jokerText = ChildHomeView.jokerText(streak) {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(NotoTheme.Colors.info)
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
        .accessibilityLabel(ChildHomeView.streakAccessibilityLabel(streak))
    }

    private func rewardStatusCard(_ text: (title: String, detail: String?)) -> some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Image(systemName: rewardStatus == .afterClass ? "clock" : "lock.open.fill")
                .foregroundStyle(NotoTheme.Colors.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title)
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = text.detail {
                    Text(detail)
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Contrôle

    private func examCard(_ exam: ExamTomorrow) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
                Image(systemName: "list.clipboard")
                    .foregroundStyle(NotoTheme.Colors.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exam.subject.map { "Contrôle demain : \($0.capitalized)" } ?? "Contrôle demain")
                        .font(ChildStyle.headline)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text(Self.examPitch(bonus: examBonus))
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if canQuiz {
                ChildPrimaryButton(title: "Réviser maintenant", action: onStartQuiz)
                    .accessibilityHint("Lance le quiz du jour, qui commence par tes devoirs de demain")
            }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .signalCard(.info)
    }

    // MARK: - Ma journée

    private var daySection: some View {
        let now = Date()
        let homework = (child?.homework ?? []).map { HomeworkSnapshot($0, calendar: .current) }
        let lines = Self.homeworkLines(lessonSubjects: lessons.map(\.subject), homework: homework,
                                       now: now, calendar: .current)
        let lockText = classLockActive ? Self.classLockText(lastLessonEnd: lessons.map(\.end).max(), now: now) : nil
        let classesLeft = lessons.contains { $0.end > now }

        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Ma journée")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                if let lockText {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .accessibilityHidden(true)
                        Text(lockText)
                            .font(ChildStyle.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 10)
                    .background(NotoTheme.Colors.surfaceElevated)
                    .accessibilityElement(children: .combine)
                }

                if lessons.isEmpty {
                    Text("Pas de cours aujourd'hui.")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(NotoTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                        if index > 0 || lockText != nil { SettingsDivider() }
                        lessonRow(lesson, homework: lines[index], now: now)
                    }
                }

                SettingsDivider()
                quizRow(afterClass: classesLeft)
            }
            .notoCard()
        }
    }

    private func lessonRow(_ lesson: ScheduleEntry, homework: HomeworkSnapshot?, now: Date) -> some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
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
                if let homework {
                    Text("\(Self.homeworkDueLabel(homework.dueDate, now: now, calendar: .current)) : "
                         + homework.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(ChildStyle.caption)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func quizRow(afterClass: Bool) -> some View {
        let label = HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
            Image(systemName: "sparkles")
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.info)
                .frame(minWidth: 48, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ton quiz du jour")
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(canQuiz
                     ? (afterClass ? "Après les cours, quand tu veux · 3 min" : "Quand tu veux · 3 min")
                     : "Les questions arrivent bientôt")
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
            if canQuiz {
                Image(systemName: "chevron.right")
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: ChildStyle.minTapTarget)
        .contentShape(Rectangle())

        if canQuiz {
            Button(action: onStartQuiz) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Lance un petit quiz de quelques questions")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    // MARK: - Copy (pure, tested through `ChildTodayCopyTests`)

    /// « Lundi 19 octobre ».
    static func dateLine(_ date: Date, locale: Locale = Locale(identifier: "fr_FR")) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func examPitch(bonus: Int?) -> String {
        guard let bonus else { return "Un petit quiz ce soir pour t'échauffer ?" }
        return "Un petit quiz ce soir pour t'échauffer ? +\(bonus) min de bonus."
    }

    /// Said only while classes are still on: the class lock is absolute, the
    /// cagnotte never lifts it.
    static func classLockText(lastLessonEnd: Date?, now: Date,
                              locale: Locale = Locale(identifier: "fr_FR")) -> String? {
        guard let lastLessonEnd, now < lastLessonEnd else { return nil }
        let time = lastLessonEnd.formatted(.dateTime.hour().minute().locale(locale))
        return "Pendant les cours, tes applis sont en pause jusqu'à \(time)."
    }

    /// For each lesson, in order, the next homework of its subject still to
    /// do (due tomorrow or later), shown once per subject, under its first
    /// lesson of the day.
    static func homeworkLines(lessonSubjects: [String], homework: [HomeworkSnapshot],
                              now: Date, calendar: Calendar) -> [HomeworkSnapshot?] {
        let tomorrow = calendar.quizStartOfDay(addingDays: 1, to: now)
        var shown = Set<String>()
        return lessonSubjects.map { subject in
            let folded = SubjectAlias.fold(subject)
            guard shown.insert(folded).inserted else { return nil }
            return homework
                .filter { !$0.done && $0.dueDate >= tomorrow && SubjectAlias.fold($0.subject) == folded }
                .min { $0.dueDate < $1.dueDate }
        }
    }

    /// « Pour demain », else « Pour jeudi ».
    static func homeworkDueLabel(_ due: Date, now: Date, calendar: Calendar,
                                 locale: Locale = Locale(identifier: "fr_FR")) -> String {
        if calendar.isDate(due, inSameDayAs: calendar.quizStartOfDay(addingDays: 1, to: now)) {
            return "Pour demain"
        }
        return "Pour " + due.formatted(.dateTime.weekday(.wide).locale(locale))
    }
}
