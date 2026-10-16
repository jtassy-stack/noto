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

/// « Mon parcours »: the themes of the child's level per subject, each with
/// its progress (five dots = Leitner boxes). Child mode, tutoiement.
struct SubjectPathView: View {
    let child: Child
    var curriculum: CurriculumSnapshot = .bundled

    private var subjects: [SubjectProgress] {
        SubjectProgress.path(level: child.grade, specialties: child.specialties,
                             masteries: child.notionMasteries.map { MasterySnapshot($0) },
                             curriculum: curriculum)
    }

    var body: some View {
        let subjects = self.subjects
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                if subjects.isEmpty {
                    ChildEmptyState(systemImage: "map",
                                    title: "Ton parcours arrive bientôt",
                                    message: "Les thèmes de ta classe apparaîtront ici.")
                } else {
                    Text("Chaque quiz fait avancer tes thèmes : plus il y a de points verts, mieux tu les connais.")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    ForEach(subjects) { subject in
                        subjectSection(subject)
                    }
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
        .navigationTitle("Mon parcours")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func subjectSection(_ subject: SubjectProgress) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(subject.subject)
                    .font(ChildStyle.subject)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(subject.masteredCount)/\(subject.themes.count)")
                    .font(ChildStyle.caption.monospacedDigit())
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .accessibilityLabel("\(subject.masteredCount) thèmes maîtrisés sur \(subject.themes.count)")
            }
            .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(subject.themes.enumerated()), id: \.element.id) { index, theme in
                    if index > 0 { SettingsDivider() }
                    themeRow(theme)
                }
            }
            .notoCard()
        }
    }

    private func themeRow(_ theme: ThemeProgress) -> some View {
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
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: ChildStyle.minTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.theme). \(Self.status(theme))")
    }

    static func status(_ theme: ThemeProgress) -> String {
        switch theme.box {
        case ...0: "À découvrir"
        case 4...: "Tu maîtrises"
        default: "En cours : \(theme.box) sur 5"
        }
    }
}

#Preview("Mon parcours") {
    NavigationStack {
        SubjectPathView(child: PreviewData.revisionChild)
    }
    .withPreviewData()
}
