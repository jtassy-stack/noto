import SwiftUI

/// « Mes cours » (child app): the child's own homework, timetable and, when
/// the parent leaves them visible (`ChildGradesSettings`), grades. Read-only
/// view of what this device already synced from the school; nothing leaves
/// the device. Logic in `ChildCourses`. Every string addresses the child
/// (tutoiement, CLAUDE.md exception for `DeviceMode.child`). Grades are shown
/// neutrally: no red, no class comparison (amber stays the série's colour).
struct ChildCoursesView: View {
    let child: Child
    let gradesVisible: Bool
    @State private var section: ChildCourses.Section = .homework
    @State private var selectedDay: Date?

    private static let locale = Locale(identifier: "fr_FR")

    var body: some View {
        let sections = ChildCourses.sections(gradesVisible: gradesVisible)
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                Text("Mes cours")
                    .font(ChildStyle.greeting)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Picker("Rubrique", selection: $section) {
                    ForEach(sections) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                switch section {
                case .homework: homeworkSection
                case .schedule: scheduleSection
                case .grades:   gradesSection
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
        .onChange(of: gradesVisible) { _, visible in
            if !visible && section == .grades { section = .homework }
        }
    }

    // MARK: - Devoirs

    private var homeworkSection: some View {
        let now = Date()
        let days = ChildCourses.homeworkDays(
            child.homework.map { HomeworkSnapshot($0, calendar: .current) },
            now: now, calendar: .current
        )
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
            if days.isEmpty {
                ChildEmptyState(systemImage: "checkmark.circle",
                                title: "Rien à faire pour l'instant",
                                message: "Quand tes profs donnent des devoirs, ils s'affichent ici.")
            } else {
                ForEach(days, id: \.day) { day in
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                        Text(day.label)
                            .childSectionLabel()
                            .padding(.horizontal, NotoTheme.Spacing.xs)
                        VStack(spacing: 0) {
                            ForEach(Array(day.items.enumerated()), id: \.offset) { index, item in
                                if index > 0 { SettingsDivider() }
                                homeworkRow(item)
                            }
                        }
                        .notoCard()
                    }
                }
            }
        }
    }

    private func homeworkRow(_ item: HomeworkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.subject)
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            let text = item.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                Text(text)
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Emploi du temps

    private var scheduleSection: some View {
        let now = Date()
        let calendar = Calendar.current
        let days = ChildCourses.scheduleDays(lessonStarts: child.schedule.map(\.start), now: now, calendar: calendar)
        let day = selectedDay.flatMap { selected in days.first { calendar.isDate($0, inSameDayAs: selected) } }
            ?? days.first
        let lessons = day.map { day in
            child.schedule
                .filter { calendar.isDate($0.start, inSameDayAs: day) }
                .sorted { $0.start < $1.start }
        } ?? []

        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
            if days.isEmpty {
                ChildEmptyState(systemImage: "calendar",
                                title: "Pas de cours à venir",
                                message: "Ton emploi du temps s'affiche ici après la prochaine synchro.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        ForEach(days, id: \.self) { chip in
                            let isSelected = day.map { calendar.isDate($0, inSameDayAs: chip) } ?? false
                            Button {
                                selectedDay = chip
                            } label: {
                                Text(ChildCourses.dayChipLabel(chip, now: now, calendar: calendar))
                                    .font(ChildStyle.caption.weight(.medium))
                                    .foregroundStyle(isSelected ? Color.white : NotoTheme.Colors.textPrimary)
                                    .padding(.horizontal, NotoTheme.Spacing.md)
                                    .frame(minHeight: ChildStyle.minTapTarget)
                                    .background(isSelected ? ChildStyle.accent : NotoTheme.Colors.surfaceElevated)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(lessons.enumerated()), id: \.offset) { index, lesson in
                        if index > 0 { SettingsDivider() }
                        lessonRow(lesson)
                    }
                }
                .notoCard()
            }
        }
    }

    private func lessonRow(_ lesson: ScheduleEntry) -> some View {
        let time = lesson.start.formatted(.dateTime.hour().minute().locale(Self.locale))
            + " – " + lesson.end.formatted(.dateTime.hour().minute().locale(Self.locale))
        let details = [lesson.room, lesson.teacher].compactMap { $0 }.filter { !$0.isEmpty }
        return HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
            Text(time)
                .font(ChildStyle.caption.monospacedDigit())
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .frame(minWidth: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(lesson.subject)
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .strikethrough(lesson.cancelled)
                if lesson.cancelled {
                    Text("Cours annulé")
                        .font(ChildStyle.caption.weight(.medium))
                        .foregroundStyle(NotoTheme.Colors.info)
                } else if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(ChildStyle.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Notes

    private var gradesSection: some View {
        let subjects = ChildCourses.subjects(child.grades.map {
            ChildCourses.GradeSnapshot(subject: $0.subject, value: $0.value, outOf: $0.outOf,
                                       coefficient: $0.coefficient, date: $0.date, chapter: $0.chapter)
        })
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
            if subjects.isEmpty {
                ChildEmptyState(systemImage: "chart.bar",
                                title: "Pas encore de notes",
                                message: "Tes notes s'affichent ici dès que tes profs les publient.")
            } else {
                ForEach(subjects, id: \.subject) { subject in
                    subjectCard(subject)
                }
            }
        }
    }

    private func subjectCard(_ subject: ChildCourses.SubjectGrades) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(subject.subject)
                    .font(ChildStyle.subject)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Spacer(minLength: NotoTheme.Spacing.sm)
                if let average = subject.average {
                    Text("Ta moyenne \(ChildCourses.averageText(average))")
                        .font(ChildStyle.caption.weight(.medium))
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)

            ForEach(Array(subject.grades.enumerated()), id: \.offset) { _, grade in
                SettingsDivider()
                gradeRow(grade)
            }
        }
        .notoCard()
    }

    private func gradeRow(_ grade: ChildCourses.GradeSnapshot) -> some View {
        let date = grade.date.formatted(.dateTime.day().month(.abbreviated).locale(Self.locale))
        let meta = [date, ChildCourses.coefficientText(grade.coefficient)].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                if let chapter = grade.chapter, !chapter.isEmpty {
                    Text(chapter)
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .lineLimit(2)
                }
                Text(meta)
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
            Text(ChildCourses.gradeText(grade))
                .font(ChildStyle.headline.monospacedDigit())
                .foregroundStyle(NotoTheme.Colors.textPrimary)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
