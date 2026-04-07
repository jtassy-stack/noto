import SwiftUI
import SwiftData

struct SchoolView: View {
    let selectedChild: Child?

    @Query private var families: [Family]
    @State private var selectedSection: SchoolSection = .grades

    private var children: [Child] {
        if let child = selectedChild { return [child] }
        return families.first?.children ?? []
    }

    private var hasData: Bool {
        children.contains { !$0.grades.isEmpty || !$0.schedule.isEmpty || !$0.homework.isEmpty }
    }

    var body: some View {
        NavigationStack {
            if hasData {
                VStack(spacing: 0) {
                    // Section picker
                    Picker("Section", selection: $selectedSection) {
                        ForEach(SchoolSection.allCases, id: \.self) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, NotoTheme.Spacing.sm)

                    // Content
                    switch selectedSection {
                    case .grades:
                        GradesListView(children: children)
                    case .schedule:
                        ScheduleListView(children: children)
                    case .homework:
                        HomeworkListView(children: children)
                    }
                }
                .navigationTitle("École")
                .navigationBarTitleDisplayMode(.large)
            } else {
                ContentUnavailableView(
                    "École",
                    systemImage: "book.closed",
                    description: Text("Aucune donnée scolaire. Lancez une synchronisation depuis l'accueil.")
                )
                .navigationTitle("École")
                .navigationBarTitleDisplayMode(.large)
            }
        }
    }
}

// MARK: - Section

enum SchoolSection: String, CaseIterable {
    case grades
    case schedule
    case homework

    var title: String {
        switch self {
        case .grades: "Notes"
        case .schedule: "EDT"
        case .homework: "Devoirs"
        }
    }
}

// MARK: - Grades

private struct GradesListView: View {
    let children: [Child]

    private var allGrades: [(child: Child, grade: Grade)] {
        children.flatMap { child in
            child.grades.map { (child: child, grade: $0) }
        }.sorted { $0.grade.date > $1.grade.date }
    }

    var body: some View {
        if allGrades.isEmpty {
            ContentUnavailableView("Pas de notes", systemImage: "chart.bar", description: Text("Les notes apparaîtront après synchronisation."))
        } else {
            List(allGrades, id: \.grade.id) { item in
                GradeRow(grade: item.grade, showChild: children.count > 1, childName: item.child.firstName)
            }
            .listStyle(.plain)
        }
    }
}

private struct GradeRow: View {
    let grade: Grade
    let showChild: Bool
    let childName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                if showChild {
                    Text(childName)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(grade.subject)
                    .font(NotoTheme.Typography.headline)
                if let chapter = grade.chapter {
                    Text(chapter)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(grade.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            Spacer()

            // Grade value
            Text(String(format: "%.1f", grade.value))
                .font(NotoTheme.Typography.data)
                .foregroundStyle(gradeColor)
            Text("/\(Int(grade.outOf))")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
    }

    private var gradeColor: Color {
        let normalized = grade.normalizedValue
        if normalized >= 14 { return NotoTheme.Colors.success }
        if normalized >= 10 { return NotoTheme.Colors.textPrimary }
        if normalized >= 8 { return NotoTheme.Colors.warning }
        return NotoTheme.Colors.danger
    }
}

// MARK: - Schedule

private struct ScheduleListView: View {
    let children: [Child]

    private var todayEntries: [(child: Child, entry: ScheduleEntry)] {
        let today = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        return children.flatMap { child in
            child.schedule
                .filter { $0.start >= today && $0.start < tomorrow }
                .map { (child: child, entry: $0) }
        }.sorted { $0.entry.start < $1.entry.start }
    }

    var body: some View {
        if todayEntries.isEmpty {
            ContentUnavailableView("Pas de cours aujourd'hui", systemImage: "calendar", description: Text("L'emploi du temps apparaîtra après synchronisation."))
        } else {
            List(todayEntries, id: \.entry.id) { item in
                ScheduleRow(entry: item.entry, showChild: children.count > 1, childName: item.child.firstName)
            }
            .listStyle(.plain)
        }
    }
}

private struct ScheduleRow: View {
    let entry: ScheduleEntry
    let showChild: Bool
    let childName: String

    var body: some View {
        HStack {
            // Time
            VStack(alignment: .trailing) {
                Text(entry.start.formatted(.dateTime.hour().minute()))
                    .font(NotoTheme.Typography.data)
                Text(entry.end.formatted(.dateTime.hour().minute()))
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            .frame(width: 50)

            Rectangle()
                .fill(entry.cancelled ? NotoTheme.Colors.danger : NotoTheme.Colors.brand)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                if showChild {
                    Text(childName)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(entry.subject)
                    .font(NotoTheme.Typography.headline)
                    .strikethrough(entry.cancelled)
                    .foregroundStyle(entry.cancelled ? NotoTheme.Colors.danger : NotoTheme.Colors.textPrimary)

                if entry.cancelled {
                    Text("Annulé")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.danger)
                }

                if let room = entry.room {
                    Text("Salle \(room)")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Homework

private struct HomeworkListView: View {
    let children: [Child]

    private var pendingHomework: [(child: Child, hw: Homework)] {
        children.flatMap { child in
            child.homework
                .filter { !$0.done && $0.dueDate >= .now }
                .map { (child: child, hw: $0) }
        }.sorted { $0.hw.dueDate < $1.hw.dueDate }
    }

    var body: some View {
        if pendingHomework.isEmpty {
            ContentUnavailableView("Pas de devoirs", systemImage: "pencil.and.list.clipboard", description: Text("Les devoirs apparaîtront après synchronisation."))
        } else {
            List(pendingHomework, id: \.hw.id) { item in
                HomeworkRow(hw: item.hw, showChild: children.count > 1, childName: item.child.firstName)
            }
            .listStyle(.plain)
        }
    }
}

private struct HomeworkRow: View {
    let hw: Homework
    let showChild: Bool
    let childName: String

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            HStack {
                if showChild {
                    Text(childName)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Spacer()
                Text(dueLabel)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(isUrgent ? NotoTheme.Colors.danger : NotoTheme.Colors.textSecondary)
            }

            Text(hw.subject)
                .font(NotoTheme.Typography.headline)

            Text(hw.descriptionText)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .lineLimit(3)
        }
    }

    private var isUrgent: Bool {
        Calendar.current.isDateInToday(hw.dueDate) || Calendar.current.isDateInTomorrow(hw.dueDate)
    }

    private var dueLabel: String {
        if Calendar.current.isDateInToday(hw.dueDate) { return "Aujourd'hui" }
        if Calendar.current.isDateInTomorrow(hw.dueDate) { return "Demain" }
        return "Pour le " + hw.dueDate.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }
}
