import SwiftUI
import SwiftData

/// Progress of one programme theme, from the child's `NotionMastery`
/// (theme-level Leitner key, as `QuizSession` writes it).
struct ThemeProgress: Identifiable, Equatable, Sendable {
    let theme: String
    /// 0 = not started yet, else Leitner box 1…5.
    let box: Int
    var id: String { theme }
    var isMastered: Bool { box >= 4 }
}

struct SubjectProgress: Identifiable, Equatable, Sendable {
    let subject: String
    let themes: [ThemeProgress]
    var id: String { subject }
    var masteredCount: Int { themes.filter(\.isMastered).count }
}

extension SubjectProgress {
    /// The child's level programme, subject by subject, in curriculum order,
    /// with each theme's box. Pure. Empty outside 6e → Tle. A spécialité the
    /// child does not take has no theme here and is left out.
    static func path(level rawLevel: String, specialties: [String], masteries: [MasterySnapshot],
                     curriculum: some CurriculumLookup) -> [SubjectProgress] {
        let level = CurriculumService.canonicalLevel(rawLevel)
        guard CurriculumService.revisionLevels.contains(level) else { return [] }
        let boxes = Dictionary(masteries.map { ($0.notionKey, $0.leitnerBox) }, uniquingKeysWith: { max($0, $1) })
        var seen = Set<String>()
        return curriculum.subjects(for: level)
            .filter { seen.insert($0).inserted }
            .compactMap { subject in
                let themes = curriculum.themes(for: level, subject: subject, specialties: specialties)
                guard !themes.isEmpty else { return nil }
                return SubjectProgress(subject: subject, themes: themes.map { theme in
                    let key = NotionKey.make(level: level, subject: subject, theme: theme.theme)
                    return ThemeProgress(theme: theme.theme, box: boxes[key] ?? 0)
                })
            }
    }
}

/// « Parcours », the child app's third tab: one subject at a time (scrolling
/// pills, so a lycée timetable of ten subjects and more fits), its XP and
/// level (`Gamification`, 3.6), the theme taught in class now (cahier de
/// textes, `ProgrammePosition`) on top, then the year's themes with their
/// progress. Mastered is green, a theme in progress is cobalt (« à revoir »
/// is an information, amber is kept for the série). A theme already met in
/// class or in a quiz can be revised on its own (« Réviser ce thème »).
/// Child mode, tutoiement.
struct SubjectPathView: View {
    let child: Child
    /// The subject shown; nil = the first one taught in class now, else the
    /// first of the programme. « Réviser » sets it to open a subject.
    @Binding var selectedSubject: String?
    var curriculum: CurriculumSnapshot = .bundled
    /// Opens a quiz on that theme; nil = themes are not playable here.
    var onRevise: ((QuizFocus) -> Void)?

    @Environment(\.modelContext) private var modelContext

    init(child: Child, selectedSubject: Binding<String?> = .constant(nil), curriculum: CurriculumSnapshot = .bundled,
         onRevise: ((QuizFocus) -> Void)? = nil) {
        self.child = child
        self._selectedSubject = selectedSubject
        self.curriculum = curriculum
        self.onRevise = onRevise
    }

    private var subjects: [SubjectProgress] {
        SubjectProgress.path(level: child.grade, specialties: child.specialties,
                             masteries: child.notionMasteries.map { MasterySnapshot($0) },
                             curriculum: curriculum)
    }

    var body: some View {
        let subjects = self.subjects
        let xp = GamificationStore.subjectXP(of: child)
        let position = QuizSession.plan(for: child, curriculum: curriculum).position
        let current = Self.resolvedSubject(selectedSubject, subjects: subjects, position: position)
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                Text("Mon parcours")
                    .font(ChildStyle.greeting)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, NotoTheme.Spacing.sm)

                if subjects.isEmpty {
                    ChildEmptyState(systemImage: "map",
                                    title: "Ton parcours arrive bientôt",
                                    message: "Les thèmes de ta classe apparaîtront ici.")
                } else {
                    subjectPills(subjects, current: current?.subject)
                    if let current {
                        let inClass = Self.inClassThemes(of: current, position: position)
                        subjectSection(current, xp: Gamification.xp(for: current.subject, in: xp),
                                       inClass: inClass,
                                       playable: playableThemes(of: current, inClass: inClass, position: position))
                    }
                    legend
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
    }

    private func subjectPills(_ subjects: [SubjectProgress], current: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                ForEach(subjects) { subject in
                    let isSelected = subject.subject == current
                    Button {
                        selectedSubject = subject.subject
                    } label: {
                        Text(subject.subject)
                            .font(ChildStyle.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : NotoTheme.Colors.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: ChildStyle.minTapTarget)
                            .background(isSelected ? ChildStyle.accent : NotoTheme.Colors.surface,
                                        in: Capsule())
                            .overlay {
                                if !isSelected { Capsule().stroke(NotoTheme.Colors.border, lineWidth: 1) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// Themes that open a quiz: met already (taught in class, or played) and
    /// with at least one question.
    private func playableThemes(of subject: SubjectProgress, inClass: [ThemeProgress],
                                position: ProgrammePosition) -> Set<String> {
        guard onRevise != nil else { return [] }
        let met = Self.metThemes(of: subject, inClass: inClass, position: position)
        guard !met.isEmpty else { return [] }
        let counts = QuizSession.availableCounts(
            for: child, in: modelContext,
            focuses: met.map { QuizFocus(subject: subject.subject, theme: $0.theme) })
        return Set(zip(met, counts).filter { $0.1 > 0 }.map(\.0.theme))
    }

    private func subjectSection(_ subject: SubjectProgress, xp: Int, inClass: [ThemeProgress],
                                playable: Set<String>) -> some View {
        let others = subject.themes.filter { theme in !inClass.contains(theme) }
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
            SubjectLevelBar(xp: xp)
                .padding(NotoTheme.Spacing.md)
                .notoCard()

            if !inClass.isEmpty {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                    Text("En classe en ce moment")
                        .childSectionLabel()
                        .padding(.horizontal, NotoTheme.Spacing.xs)
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                        ForEach(inClass) { theme in
                            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                                Text(theme.theme)
                                    .font(ChildStyle.title)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: NotoTheme.Spacing.sm) {
                                    MasteryDots(box: theme.box)
                                    Text(Self.status(theme))
                                        .font(ChildStyle.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("En classe : \(theme.theme). \(Self.status(theme))")
                                if playable.contains(theme.theme), let onRevise {
                                    ChildPrimaryButton(title: "Réviser ce thème") {
                                        onRevise(QuizFocus(subject: subject.subject, theme: theme.theme))
                                    }
                                    .padding(.top, NotoTheme.Spacing.xs)
                                    .accessibilityHint("Lance un quiz sur ce thème")
                                }
                            }
                        }
                    }
                    .padding(NotoTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .signalCard(.info)
                }
            }

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Les thèmes de l'année")
                            .childSectionLabel()
                        Spacer()
                        Text("\(subject.masteredCount)/\(subject.themes.count)")
                            .font(ChildStyle.caption.monospacedDigit())
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .accessibilityLabel("\(subject.masteredCount) thèmes maîtrisés sur \(subject.themes.count)")
                    }
                    .padding(.horizontal, NotoTheme.Spacing.xs)
                    VStack(spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, theme in
                            if index > 0 { SettingsDivider() }
                            if playable.contains(theme.theme), let onRevise {
                                Button {
                                    onRevise(QuizFocus(subject: subject.subject, theme: theme.theme))
                                } label: {
                                    themeRow(theme, playable: true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Lance un quiz sur ce thème")
                            } else {
                                themeRow(theme, playable: false)
                            }
                        }
                    }
                    .notoCard()
                }
            }
        }
    }

    private func themeRow(_ theme: ThemeProgress, playable: Bool) -> some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.theme)
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.status(theme))
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer(minLength: NotoTheme.Spacing.sm)
            MasteryDots(box: theme.box)
            if playable {
                Image(systemName: "chevron.right")
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: ChildStyle.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.theme). \(Self.status(theme))")
    }

    private var legend: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            legendItem(NotoTheme.Colors.success, "maîtrisé")
            legendItem(NotoTheme.Colors.info, "en cours")
            legendItem(NotoTheme.Colors.border, "pas encore")
        }
        .font(ChildStyle.caption)
        .foregroundStyle(NotoTheme.Colors.textSecondary)
        .padding(.horizontal, NotoTheme.Spacing.xs)
        .accessibilityHidden(true)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    static func status(_ theme: ThemeProgress) -> String {
        switch theme.box {
        case ...0: "À découvrir"
        case 4...: "Tu maîtrises"
        default: "En cours : \(theme.box) sur 5"
        }
    }

    /// The selected subject when it is in the path, else the first one with a
    /// theme taught in class now, else the first of the programme.
    static func resolvedSubject(_ selected: String?, subjects: [SubjectProgress],
                                position: ProgrammePosition) -> SubjectProgress? {
        if let selected,
           let match = subjects.first(where: { SubjectAlias.fold($0.subject) == SubjectAlias.fold(selected) }) {
            return match
        }
        return subjects.first { !(position.position(forSubject: $0.subject)?.current.isEmpty ?? true) }
            ?? subjects.first
    }

    /// Themes the child has met: taught in class now or before (cahier de
    /// textes), or already played (Leitner box > 0). Never a theme not
    /// reached yet, as in the quiz of the day.
    static func metThemes(of subject: SubjectProgress, inClass: [ThemeProgress],
                          position: ProgrammePosition) -> [ThemeProgress] {
        let seen = Set((position.position(forSubject: subject.subject)?.all ?? []).map { SubjectAlias.fold($0.theme) })
        return subject.themes.filter { theme in
            theme.box > 0 || inClass.contains(theme) || seen.contains(SubjectAlias.fold(theme.theme))
        }
    }

    /// The subject's themes taught in class now, in the tracker's order.
    static func inClassThemes(of subject: SubjectProgress, position: ProgrammePosition) -> [ThemeProgress] {
        guard let current = position.position(forSubject: subject.subject)?.current else { return [] }
        return current.compactMap { sighting in
            subject.themes.first { SubjectAlias.fold($0.theme) == SubjectAlias.fold(sighting.theme) }
        }
    }
}

/// « Niveau 2 · 140 XP » and the progress towards the next level.
struct SubjectLevelBar: View {
    let xp: Int

    var body: some View {
        let progress = Gamification.level(forXP: xp)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Niveau \(progress.level)")
                    .font(ChildStyle.caption.weight(.semibold))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Spacer()
                Text("\(xp) XP")
                    .font(ChildStyle.caption.monospacedDigit())
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            ProgressView(value: Double(progress.xpIntoLevel), total: Double(max(1, progress.xpForNextLevel)))
                .tint(ChildStyle.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(xp: xp))
    }

    static func accessibilityLabel(xp: Int) -> String {
        let progress = Gamification.level(forXP: xp)
        let remaining = progress.xpForNextLevel - progress.xpIntoLevel
        return "Niveau \(progress.level), \(xp) points d'expérience. "
            + "Encore \(remaining) pour le niveau \(progress.level + 1)."
    }
}

#Preview("Mon parcours") {
    NavigationStack {
        SubjectPathView(child: PreviewData.revisionChild)
    }
    .withPreviewData()
}
