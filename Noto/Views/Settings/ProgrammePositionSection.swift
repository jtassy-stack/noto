import SwiftUI

/// « Où en est votre enfant » (Phase 3.8), parent tone (vouvoiement): per
/// subject, the programme theme(s) being taught now and those already seen,
/// inferred on the device from the cahier de textes and homework by
/// `ProgrammePositionTracker`. Shown in `RevisionsView` (Réglages, behind the
/// parent PIN in child mode), never in the child app.
///
/// Privacy: theme labels only (public programme data), never the raw lesson
/// text or teacher notes. Nothing is sent anywhere; nothing is stored.
struct ProgrammePositionSection: View {
    let child: Child

    var body: some View {
        let position = Self.position(for: child)
        VStack(alignment: .leading, spacing: 0) {
            Text("Où en est votre enfant")
                .font(NotoTheme.Typography.signalTitle)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.top, NotoTheme.Spacing.md)
                .padding(.bottom, NotoTheme.Spacing.xs)

            if position.hasAny {
                ForEach(Array(position.orderedSubjects.enumerated()), id: \.element.subject) { index, subject in
                    if index > 0 { SettingsDivider() }
                    SubjectPositionRow(position: subject)
                }
            } else {
                Text(Self.emptyText)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.footerText)
                if !position.unmatchedSubjects.isEmpty {
                    Text("Matières non reconnues : " + position.unmatchedSubjects.joined(separator: ", "))
                }
            }
            .font(.footnote)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.bottom, 12)
            .padding(.top, NotoTheme.Spacing.xs)
        }
        .notoCard()
    }

    // MARK: - Data

    /// Computed live from the local store (no state, nothing persisted).
    @MainActor
    static func position(for child: Child, curriculum: CurriculumSnapshot = .bundled,
                         now: Date = Date(), calendar: Calendar = .current) -> ProgrammePosition {
        ProgrammePositionTracker.compute(
            level: child.grade, specialties: child.specialties,
            lessons: child.lessonContents.filter { !$0.isDeleted }.map { LessonContentSnapshot($0) },
            homework: child.homework.filter { !$0.isDeleted }.map { HomeworkSnapshot($0, calendar: calendar) },
            curriculum: curriculum, now: now, calendar: calendar)
    }

    // MARK: - Copy (parent-addressed)

    static let emptyText = "Nous n'avons pas encore assez d'éléments du cahier de textes pour situer votre "
        + "enfant dans le programme. Les révisions suivent le calendrier officiel."
    static let footerText = "Calculé sur votre téléphone à partir du cahier de textes et des devoirs. "
        + "Rien n'est envoyé."

    static func currentLabel(_ current: [ProgrammePosition.Sighting]) -> String {
        let themes = current.map(\.theme)
        guard let first = themes.first else { return "En ce moment : —" }
        return themes.count > 1 ? "En ce moment : \(first) et \(themes[1])" : "En ce moment : \(first)"
    }

    static func coveredLabel(_ count: Int) -> String {
        switch count {
        case 0: return "Déjà vu : aucun autre thème"
        case 1: return "Déjà vu : 1 thème"
        default: return "Déjà vu : \(count) thèmes"
        }
    }

    static func confidenceLabel(_ confidence: ProgrammePosition.Confidence) -> String {
        switch confidence {
        case .high: return "Indication fiable"
        case .medium: return "À confirmer"
        case .low: return "Peu d'éléments"
        }
    }

    /// « vu le 12 oct. » (a future due date reads as today).
    static func seenLabel(_ date: Date, now: Date = Date()) -> String {
        let shown = min(date, now)
        return "vu le " + shown.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }
}

private struct SubjectPositionRow: View {
    let position: ProgrammePosition.SubjectPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: NotoTheme.Spacing.sm) {
                Text(position.subject)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Spacer()
                Text(ProgrammePositionSection.confidenceLabel(position.confidence))
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(chipColor)
                    .padding(.horizontal, NotoTheme.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(chipColor.opacity(0.12), in: Capsule())
            }
            Text(ProgrammePositionSection.currentLabel(position.current))
                .font(NotoTheme.Typography.metadata)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            if position.covered.isEmpty {
                Text(ProgrammePositionSection.coveredLabel(0))
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(position.covered, id: \.notionKey) { sighting in
                            Text("\(sighting.theme) · \(ProgrammePositionSection.seenLabel(sighting.lastSeen))")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(ProgrammePositionSection.coveredLabel(position.covered.count))
                        .font(NotoTheme.Typography.metadata)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .tint(NotoTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
    }

    private var chipColor: Color {
        switch position.confidence {
        case .high: NotoTheme.Colors.success
        case .medium: NotoTheme.Colors.warning
        case .low: NotoTheme.Colors.textSecondary
        }
    }
}
