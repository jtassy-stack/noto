import SwiftUI
import SwiftData

struct SchoolView: View {
    let selectedChild: Child?

    @Query private var families: [Family]
    @State private var selectedSection: SchoolSection?

    private var children: [Child] {
        if let child = selectedChild { return [child] }
        return families.first?.children ?? []
    }

    private var hasData: Bool {
        children.contains {
            !$0.grades.isEmpty || !$0.schedule.isEmpty || !$0.homework.isEmpty || !$0.messages.isEmpty
        }
    }

    /// Available sections depend on child type
    private var availableSections: [SchoolSection] {
        if let child = selectedChild {
            return child.schoolType == .pronote
                ? [.grades, .schedule, .homework, .messages]
                : [.schoolbook, .homework, .messages]  // PCN: no grades, no schedule
        }
        // Famille mode: union of both
        let hasPronote = children.contains { $0.schoolType == .pronote }
        let hasENT = children.contains { $0.schoolType == .ent }
        var sections: [SchoolSection] = []
        if hasPronote { sections.append(contentsOf: [.grades, .schedule]) }
        if hasENT { sections.append(.schoolbook) }
        sections.append(contentsOf: [.homework, .messages])
        return sections
    }

    /// Ensure selectedSection is valid for current child
    private var activeSection: SchoolSection {
        if let s = selectedSection, availableSections.contains(s) { return s }
        return availableSections.first ?? .homework
    }

    var body: some View {
        NavigationStack {
            if hasData {
                VStack(spacing: 0) {
                    Picker("Section", selection: Binding(
                        get: { activeSection },
                        set: { selectedSection = $0 }
                    )) {
                        ForEach(availableSections, id: \.self) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, NotoTheme.Spacing.sm)

                    switch activeSection {
                    case .grades:
                        GradesListView(children: children.filter { $0.schoolType == .pronote })
                    case .schedule:
                        ScheduleListView(children: children.filter { $0.schoolType == .pronote })
                    case .schoolbook:
                        SchoolbookListView(children: children.filter { $0.schoolType == .ent })
                    case .homework:
                        HomeworkListView(children: children)
                    case .messages:
                        MessagesListView(children: children)
                    }
                }
                .background(NotoTheme.Colors.background)
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
        .onChange(of: selectedChild?.id) { _, _ in
            // Reset section when switching child
            selectedSection = nil
        }
    }
}

enum SchoolSection: String, CaseIterable {
    case grades, schedule, schoolbook, homework, messages
    var title: String {
        switch self {
        case .grades: "Notes"
        case .schedule: "EDT"
        case .schoolbook: "Carnet"
        case .homework: "Devoirs"
        case .messages: "Messages"
        }
    }
}

// MARK: - Grades List

private struct GradesListView: View {
    let children: [Child]
    @State private var selectedGrade: Grade?

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
                    .contentShape(Rectangle())
                    .onTapGesture { selectedGrade = item.grade }
            }
            .listStyle(.plain)
            .sheet(item: $selectedGrade) { grade in
                GradeDetailView(grade: grade)
            }
        }
    }
}

// MARK: - Grade Row

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
                if let chapter = grade.chapter, !chapter.isEmpty {
                    Text(chapter)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(grade.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
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

// MARK: - Grade Detail

private struct GradeDetailView: View {
    let grade: Grade
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Note") {
                    HStack {
                        Text("Valeur")
                        Spacer()
                        Text("\(String(format: "%.1f", grade.value)) / \(Int(grade.outOf))")
                            .font(NotoTheme.Typography.data)
                    }
                    HStack {
                        Text("Sur 20")
                        Spacer()
                        Text(String(format: "%.1f", grade.normalizedValue))
                            .font(NotoTheme.Typography.data)
                    }
                    HStack {
                        Text("Coefficient")
                        Spacer()
                        Text(String(format: "%.1f", grade.coefficient))
                            .font(NotoTheme.Typography.data)
                    }
                }

                Section("Détails") {
                    HStack {
                        Text("Matière")
                        Spacer()
                        Text(grade.subject)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    HStack {
                        Text("Date")
                        Spacer()
                        Text(grade.date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    if let chapter = grade.chapter, !chapter.isEmpty {
                        HStack {
                            Text("Chapitre")
                            Spacer()
                            Text(chapter)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                    if let comment = grade.comment, !comment.isEmpty {
                        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                            Text("Commentaire")
                            Text(comment)
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle(grade.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Schedule List

private struct ScheduleListView: View {
    let children: [Child]
    @State private var selectedDay: Date = .now

    private var allEntries: [(child: Child, entry: ScheduleEntry)] {
        children.flatMap { child in
            child.schedule.map { (child: child, entry: $0) }
        }.sorted { $0.entry.start < $1.entry.start }
    }

    private var availableDays: [Date] {
        let days = Set(allEntries.map { Calendar.current.startOfDay(for: $0.entry.start) })
        return days.sorted()
    }

    private var entriesForSelectedDay: [(child: Child, entry: ScheduleEntry)] {
        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        return allEntries.filter { $0.entry.start >= dayStart && $0.entry.start < dayEnd }
    }

    var body: some View {
        if allEntries.isEmpty {
            ContentUnavailableView("Pas de cours", systemImage: "calendar", description: Text("L'emploi du temps apparaîtra après synchronisation."))
        } else {
            VStack(spacing: 0) {
                // Day selector
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        ForEach(availableDays, id: \.self) { day in
                            DayChip(
                                day: day,
                                isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDay),
                                action: { selectedDay = day }
                            )
                        }
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, NotoTheme.Spacing.sm)
                }

                if entriesForSelectedDay.isEmpty {
                    Spacer()
                    Text("Pas de cours ce jour")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    Spacer()
                } else {
                    List(entriesForSelectedDay, id: \.entry.id) { item in
                        ScheduleRow(entry: item.entry, showChild: children.count > 1, childName: item.child.firstName)
                    }
                    .listStyle(.plain)
                }
            }
            .onAppear {
                // Default to today if available, else first day
                if let today = availableDays.first(where: { Calendar.current.isDateInToday($0) }) {
                    selectedDay = today
                } else if let first = availableDays.first {
                    selectedDay = first
                }
            }
        }
    }
}

private struct DayChip: View {
    let day: Date
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                    .font(NotoTheme.Typography.caption)
                Text(day.formatted(.dateTime.day()))
                    .font(NotoTheme.Typography.headline)
            }
            .frame(width: 48, height: 52)
            .background(isSelected ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
            .foregroundStyle(isSelected ? NotoTheme.Colors.shadow : NotoTheme.Colors.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                    .stroke(isSelected ? Color.clear : NotoTheme.Colors.textSecondary.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ScheduleRow: View {
    let entry: ScheduleEntry
    let showChild: Bool
    let childName: String

    var body: some View {
        HStack {
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
                if let teacher = entry.teacher {
                    Text(teacher)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Schoolbook List (Carnet de liaison — PCN)

private struct SchoolbookListView: View {
    let children: [Child]
    @State private var selectedWord: Message?

    private var allWords: [(child: Child, msg: Message)] {
        children.flatMap { child in
            child.messages
                .filter { $0.kind == .schoolbook }
                .map { (child: child, msg: $0) }
        }.sorted { $0.msg.date > $1.msg.date }
    }

    var body: some View {
        if allWords.isEmpty {
            ContentUnavailableView(
                "Pas de mots",
                systemImage: "text.book.closed",
                description: Text("Le carnet de liaison apparaîtra après synchronisation.")
            )
        } else {
            List(allWords, id: \.msg.id) { item in
                SchoolbookRow(msg: item.msg, showChild: children.count > 1, childName: item.child.firstName)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedWord = item.msg }
            }
            .listStyle(.plain)
            .sheet(item: $selectedWord) { msg in
                MessageDetailView(msg: msg)
            }
        }
    }
}

private struct SchoolbookRow: View {
    let msg: Message
    let showChild: Bool
    let childName: String

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            // Acknowledged indicator
            Circle()
                .fill(msg.read ? NotoTheme.Colors.brand : NotoTheme.Colors.amber)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                HStack {
                    if showChild {
                        ChildTag(name: childName)
                    }
                    Spacer()
                    Text(msg.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(msg.sender)
                    .font(NotoTheme.Typography.headline)
                Text(msg.subject)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(2)
                if !msg.read {
                    Text("À signer")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.amber)
                }
            }
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
    }
}

// MARK: - Homework List

private struct HomeworkListView: View {
    let children: [Child]
    @State private var selectedHW: Homework?

    private var allHomework: [(child: Child, hw: Homework)] {
        children.flatMap { child in
            child.homework.map { (child: child, hw: $0) }
        }.sorted { $0.hw.dueDate < $1.hw.dueDate }
    }

    var body: some View {
        if allHomework.isEmpty {
            ContentUnavailableView("Pas de devoirs", systemImage: "pencil.and.list.clipboard", description: Text("Les devoirs apparaîtront après synchronisation."))
        } else {
            List(allHomework, id: \.hw.id) { item in
                HomeworkRow(hw: item.hw, showChild: children.count > 1, childName: item.child.firstName)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedHW = item.hw }
            }
            .listStyle(.plain)
            .sheet(item: $selectedHW) { hw in
                HomeworkDetailView(hw: hw)
            }
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

// MARK: - Homework Detail

private struct HomeworkDetailView: View {
    let hw: Homework
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                    // Subject + due date
                    HStack {
                        Label(hw.subject, systemImage: "book")
                            .font(NotoTheme.Typography.title)
                        Spacer()
                    }

                    Label(
                        hw.dueDate.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))),
                        systemImage: "calendar"
                    )
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)

                    Divider()

                    // Full description
                    Text(hw.descriptionText)
                        .font(NotoTheme.Typography.body)
                        .textSelection(.enabled)

                    if hw.done {
                        Label("Fait", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(NotoTheme.Colors.success)
                            .padding(.top, NotoTheme.Spacing.md)
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
            .navigationTitle("Devoir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Messages List

private struct MessagesListView: View {
    let children: [Child]
    @State private var selectedMessage: Message?

    private var allMessages: [(child: Child, msg: Message)] {
        children.flatMap { child in
            child.messages
                .filter { $0.kind == .conversation }
                .map { (child: child, msg: $0) }
        }.sorted { $0.msg.date > $1.msg.date }
    }

    var body: some View {
        if allMessages.isEmpty {
            ContentUnavailableView("Pas de messages", systemImage: "envelope", description: Text("Les messages apparaîtront après synchronisation."))
        } else {
            List(allMessages, id: \.msg.id) { item in
                MessageRow(msg: item.msg, showChild: children.count > 1, childName: item.child.firstName)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedMessage = item.msg }
            }
            .listStyle(.plain)
            .sheet(item: $selectedMessage) { msg in
                MessageDetailView(msg: msg)
            }
        }
    }
}

private struct MessageRow: View {
    let msg: Message
    let showChild: Bool
    let childName: String

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Circle()
                .fill(msg.read ? Color.clear : NotoTheme.Colors.brand)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                HStack {
                    if showChild {
                        Text(childName)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(msg.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(msg.sender)
                    .font(NotoTheme.Typography.headline)
                    .fontWeight(msg.read ? .regular : .semibold)
                Text(msg.subject)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
    }
}

private struct MessageDetailView: View {
    let msg: Message
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                    Text(msg.subject)
                        .font(NotoTheme.Typography.title)

                    HStack {
                        Label(msg.sender, systemImage: "person")
                        Spacer()
                        Text(msg.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                    }
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)

                    Divider()

                    Text(msg.body)
                        .font(NotoTheme.Typography.body)
                        .textSelection(.enabled)
                }
                .padding(NotoTheme.Spacing.md)
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Child Tag

struct ChildTag: View {
    let name: String
    var color: Color = NotoTheme.Colors.brand

    var body: some View {
        Text(name)
            .font(NotoTheme.Typography.dataSmall)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - Identifiable conformances for sheet

extension Grade: Identifiable {}
extension Homework: Identifiable {}
extension Message: Identifiable {}
