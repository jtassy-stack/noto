import SwiftUI
import SwiftData
import SafariServices

// MARK: - SchoolView (local child selection, no "Tous" mode)

struct SchoolView: View {
    @Query private var families: [Family]
    @State private var selectedChild: Child?
    @State private var activeTab: SchoolTab? = nil
    @State private var showAbsence = false

    private var children: [Child] {
        families.first?.children ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if children.isEmpty {
                    ContentUnavailableView(
                        "Aucun enfant",
                        systemImage: "person.2",
                        description: Text("Ajoutez un enfant dans les réglages pour commencer.")
                    )
                } else if children.count == 1 {
                    ChildSchoolView(
                        child: children[0],
                        activeTab: $activeTab,
                        showAbsence: $showAbsence
                    )
                } else if let child = selectedChild {
                    VStack(spacing: 0) {
                        SchoolChildPicker(
                            children: children,
                            selectedChild: $selectedChild
                        )
                        ChildSchoolView(
                            child: child,
                            activeTab: $activeTab,
                            showAbsence: $showAbsence
                        )
                    }
                } else {
                    SchoolChildInterstitial(
                        children: children,
                        selectedChild: $selectedChild
                    )
                }
            }
            .navigationTitle("École")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showAbsence) {
            if let child = selectedChild ?? children.first {
                AbsenceView(preselectedChild: child)
            }
        }
        .onChange(of: selectedChild?.id) { _, _ in
            activeTab = nil
        }
    }
}

// MARK: - Child picker (compact, inline)

private struct SchoolChildPicker: View {
    let children: [Child]
    @Binding var selectedChild: Child?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                ForEach(children) { child in
                    Button {
                        selectedChild = child
                    } label: {
                        HStack(spacing: NotoTheme.Spacing.xs) {
                            if child.hasAlert {
                                Circle()
                                    .fill(NotoTheme.Colors.danger)
                                    .frame(width: 6, height: 6)
                            }
                            Text(child.firstName)
                                .font(NotoTheme.Typography.caption)
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                        .background(selectedChild?.id == child.id ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                        .foregroundStyle(selectedChild?.id == child.id ? NotoTheme.Colors.shadow : NotoTheme.Colors.textPrimary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                selectedChild?.id == child.id ? Color.clear : NotoTheme.Colors.border,
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm)
        }
        .background(NotoTheme.Colors.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NotoTheme.Colors.border)
                .frame(height: 0.5)
        }
    }
}

// MARK: - Interstitial (multi-child, no selection yet)

private struct SchoolChildInterstitial: View {
    let children: [Child]
    @Binding var selectedChild: Child?

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()

            Image(systemName: "person.2.circle")
                .font(.system(size: 56))
                .foregroundStyle(NotoTheme.Colors.brand)

            Text("Quel enfant ?")
                .font(NotoTheme.Typography.title)

            Text("Sélectionnez un enfant pour consulter ses données scolaires.")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)

            VStack(spacing: NotoTheme.Spacing.md) {
                ForEach(children) { child in
                    Button {
                        selectedChild = child
                    } label: {
                        HStack(spacing: NotoTheme.Spacing.md) {
                            Text(String(child.firstName.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(NotoTheme.Colors.brand)
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(child.firstName)
                                    .font(NotoTheme.Typography.headline)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                Text(child.displayEstablishment)
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }

                            Spacer()

                            if child.hasAlert {
                                Circle()
                                    .fill(NotoTheme.Colors.danger)
                                    .frame(width: 10, height: 10)
                            }

                            Image(systemName: "chevron.right")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        .padding(NotoTheme.Spacing.md)
                        .notoCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.xl)

            Spacer()
        }
    }
}

// MARK: - Per-child school view

private struct ChildSchoolView: View {
    let child: Child
    @Binding var activeTab: SchoolTab?
    @Binding var showAbsence: Bool

    private var availableTabs: [SchoolTab] {
        switch child.schoolType {
        case .pronote:
            return [.notes, .edt, .devoirs]
        case .ent:
            return [.carnet, .devoirs]
        }
    }

    private var resolvedTab: SchoolTab {
        if let tab = activeTab, availableTabs.contains(tab) { return tab }
        return availableTabs[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Visual capsule tab picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NotoTheme.Spacing.sm) {
                    ForEach(availableTabs, id: \.self) { tab in
                        Button {
                            activeTab = tab
                        } label: {
                            Label(tab.title, systemImage: tab.icon)
                                .font(NotoTheme.Typography.caption)
                                .padding(.horizontal, NotoTheme.Spacing.md)
                                .padding(.vertical, NotoTheme.Spacing.sm)
                                .background(resolvedTab == tab ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                                .foregroundStyle(resolvedTab == tab ? NotoTheme.Colors.shadow : NotoTheme.Colors.textPrimary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm)
            }

            // Tab content
            switch resolvedTab {
            case .notes:
                GradesListView(children: [child])
            case .edt:
                ScheduleListView(children: [child])
            case .carnet:
                SchoolbookListView(children: [child])
            case .devoirs:
                HomeworkListView(children: [child])
            }
        }
        .background(NotoTheme.Colors.background)
        .toolbar {
            if child.schoolType == .ent {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAbsence = true
                    } label: {
                        Image(systemName: "envelope.badge.person.crop")
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                    }
                }
            }
        }
    }
}
// MARK: - SchoolTab enum (per-child-type)

enum SchoolTab: String, CaseIterable {
    case notes, edt, carnet, devoirs

    var title: String {
        switch self {
        case .notes:   "Notes"
        case .edt:     "EDT"
        case .carnet:  "Carnet"
        case .devoirs: "Devoirs"
        }
    }

    var icon: String {
        switch self {
        case .notes:   "chart.bar"
        case .edt:     "calendar"
        case .carnet:  "book.closed"
        case .devoirs: "pencil.and.list.clipboard"
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
            VStack {
                ContentUnavailableView("Pas de notes", systemImage: "chart.bar",
                    description: Text("Les notes apparaîtront après synchronisation."))
                Button("Synchroniser maintenant") {
                    // Navigate first so HomeView is on-screen and subscribed
                    // by the time the sync trigger fires (avoid drop).
                    NotificationCenter.default.post(name: .navigateToHome, object: nil)
                    NotificationCenter.default.post(name: .triggerFullSync, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.brand)
                .padding(.top, NotoTheme.Spacing.sm)
            }
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
            VStack(alignment: .trailing, spacing: NotoTheme.Spacing.xs) {
                Text(String(format: "%.1f", grade.value))
                    .font(NotoTheme.Typography.data)
                    .foregroundStyle(gradeColor)
                Text("/\(Int(grade.outOf))")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                if let avg = grade.classAverage, avg > 0 {
                    Text("moy. \(String(format: "%.1f", avg))")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
        }
    }

    private var gradeColor: Color {
        if let avg = grade.classAverage, avg > 0 {
            let delta = grade.normalizedValue - avg
            if delta >= 2 { return NotoTheme.Colors.success }
            if delta >= -1 { return NotoTheme.Colors.textPrimary }
            if delta >= -3 { return NotoTheme.Colors.warning }
            return NotoTheme.Colors.danger
        }
        // fallback to absolute
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

    private var isMonLyceeOnly: Bool {
        !children.isEmpty && children.allSatisfy { $0.entProvider == .monlycee }
    }

    var body: some View {
        if allEntries.isEmpty {
            if isMonLyceeOnly {
                ContentUnavailableView(
                    "EDT non disponible",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("L'emploi du temps n'est pas accessible via MonLycée.\nPour l'activer, ajoutez un enfant via QR code Pronote.")
                )
            } else {
                VStack {
                    ContentUnavailableView("Pas de cours", systemImage: "calendar",
                        description: Text("L'emploi du temps apparaîtra après synchronisation."))
                    Button("Synchroniser maintenant") {
                        // Navigate first so HomeView is on-screen and subscribed
                        // by the time the sync trigger fires (avoid drop).
                        NotificationCenter.default.post(name: .navigateToHome, object: nil)
                        NotificationCenter.default.post(name: .triggerFullSync, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotoTheme.Colors.brand)
                    .padding(.top, NotoTheme.Spacing.sm)
                }
            }
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

private struct SchoolbookSelection: Identifiable {
    let id: ObjectIdentifier
    let child: Child
    let msg: Message
}

private struct SchoolbookListView: View {
    let children: [Child]
    @State private var selection: SchoolbookSelection?

    private var allWords: [(child: Child, msg: Message)] {
        children.flatMap { child in
            child.messages
                .filter { $0.kind == .schoolbook }
                .map { (child: child, msg: $0) }
        }.sorted { $0.msg.date > $1.msg.date }
    }

    var body: some View {
        if allWords.isEmpty {
            VStack {
                ContentUnavailableView(
                    "Pas de mots",
                    systemImage: "text.book.closed",
                    description: Text("Le carnet de liaison apparaîtra après synchronisation.")
                )
                Button("Synchroniser maintenant") {
                    // Navigate first so HomeView is on-screen and subscribed
                    // by the time the sync trigger fires (avoid drop).
                    NotificationCenter.default.post(name: .navigateToHome, object: nil)
                    NotificationCenter.default.post(name: .triggerFullSync, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.brand)
                .padding(.top, NotoTheme.Spacing.sm)
            }
        } else {
            List(allWords, id: \.msg.id) { item in
                Button {
                    selection = SchoolbookSelection(id: ObjectIdentifier(item.msg), child: item.child, msg: item.msg)
                } label: {
                    SchoolbookRow(msg: item.msg, showChild: children.count > 1, childName: item.child.firstName)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .sheet(item: $selection) { item in
                SchoolbookDetailView(child: item.child, msg: item.msg)
            }
        }
    }
}

private struct SchoolbookRow: View {
    let msg: Message
    let showChild: Bool
    let childName: String

    /// Strip HTML tags for 2-line preview (body is stored as raw HTML).
    private var bodyPreview: String {
        msg.body
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                    .lineLimit(1)
                if !bodyPreview.isEmpty {
                    Text(bodyPreview)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
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
            VStack {
                ContentUnavailableView("Pas de devoirs", systemImage: "pencil.and.list.clipboard",
                    description: Text("Les devoirs apparaîtront après synchronisation."))
                Button("Synchroniser maintenant") {
                    // Navigate first so HomeView is on-screen and subscribed
                    // by the time the sync trigger fires (avoid drop).
                    NotificationCenter.default.post(name: .navigateToHome, object: nil)
                    NotificationCenter.default.post(name: .triggerFullSync, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.brand)
                .padding(.top, NotoTheme.Spacing.sm)
            }
        } else {
            List(allHomework, id: \.hw.id) { item in
                Button {
                    selectedHW = item.hw
                } label: {
                    HomeworkRow(hw: item.hw, showChild: children.count > 1, childName: item.child.firstName)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

            Button {
                NotificationCenter.default.post(name: .navigateToDiscover, object: nil)
            } label: {
                Label("Trouver une ressource", systemImage: "safari")
                    .font(NotoTheme.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotoTheme.Colors.brand)
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

                    Divider()

                    // Bridge to Discover — the moment where parental intent
                    // to find a resource is highest (Sophie C. persona).
                    Button {
                        dismiss()
                        NotificationCenter.default.post(name: .navigateToDiscover, object: nil)
                    } label: {
                        Label("Trouver une ressource", systemImage: "safari")
                            .font(NotoTheme.Typography.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NotoTheme.Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                    .tint(NotoTheme.Colors.brand)
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
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMessage: Message?
    @State private var hasIMAPCredentials = IMAPService.loadCredentials() != nil
    @State private var syncError: String?

    private var allMessages: [(child: Child, msg: Message)] {
        children.flatMap { child in
            child.messages
                .filter { $0.kind == .conversation }
                .map { (child: child, msg: $0) }
        }.sorted { $0.msg.date > $1.msg.date }
    }

    var body: some View {
        Group {
            if !hasIMAPCredentials {
                MailboxSetupView {
                    hasIMAPCredentials = true
                    Task { await syncIMAP() }
                }
            } else if allMessages.isEmpty {
                ContentUnavailableView(
                    "Pas de messages",
                    systemImage: "envelope",
                    description: Text("Tirez pour rafraîchir.")
                )
                .refreshable { await syncIMAP() }
            } else {
                List(allMessages, id: \.msg.id) { item in
                    Button { selectedMessage = item.msg } label: {
                        MessageRow(msg: item.msg, showChild: children.count > 1, childName: item.child.firstName)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .refreshable { await syncIMAP() }
                .sheet(item: $selectedMessage) { msg in
                    MessageDetailView(msg: msg)
                }
            }
        }
        .task { await syncIMAP() }
    }

    @MainActor
    private func syncIMAP() async {
        let service = IMAPSyncService(modelContext: modelContext)
        for child in children {
            do {
                try await service.sync(for: child)
            } catch {
                syncError = error.localizedDescription
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
                HStack {
                    Text(msg.sender)
                        .font(NotoTheme.Typography.headline)
                        .fontWeight(msg.read ? .regular : .semibold)
                    if msg.link != nil {
                        Image(systemName: "arrow.up.right.square")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
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
    @State private var showSafari = false

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

                    if !msg.body.isEmpty {
                        Text(msg.body)
                            .font(NotoTheme.Typography.body)
                            .textSelection(.enabled)
                    } else if let link = msg.link, let url = URL(string: link) {
                        Button {
                            showSafari = true
                        } label: {
                            Label("Voir le message", systemImage: "safari")
                                .font(NotoTheme.Typography.body)
                                .frame(maxWidth: .infinity)
                                .padding(NotoTheme.Spacing.md)
                                .background(NotoTheme.Colors.brand.opacity(0.15))
                                .foregroundStyle(NotoTheme.Colors.brand)
                                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                        }
                        .sheet(isPresented: $showSafari) {
                            SafariView(url: url)
                                .ignoresSafeArea()
                        }
                    } else {
                        Text("Contenu non disponible")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, NotoTheme.Spacing.lg)
                    }
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

// MARK: - Safari View

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
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

#Preview("École") {
    SchoolView()
        .withPreviewData()
}
