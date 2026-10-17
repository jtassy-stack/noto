import SwiftUI

/// « Moi », the child app's last tab: what rewards regularity, in one place.
/// The série month (days revised, days a joker saved), the badges earned
/// (earned only, nothing locked), the family weekly challenge when the
/// parent turned it on (the family total only, no sibling compared) and
/// Réglages behind the parent PIN. Child mode, tutoiement.
struct ChildMeView: View {
    let child: Child?
    let attempts: [AttemptSnapshot]
    /// Persisted and pending joker days.
    let jokers: [CalendarDay]
    let streak: StreakStatus
    /// Passed quizzes this week, nil when the family challenge is off.
    let familyChallengePassed: Int?
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                HStack(alignment: .firstTextBaseline) {
                    Text(child?.firstName ?? "Moi")
                        .font(ChildStyle.greeting)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let grade = child?.grade {
                        Text(grade)
                            .font(ChildStyle.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                .padding(.top, NotoTheme.Spacing.sm)

                streakMonthCard

                if let child {
                    badgesSection(child)
                }

                if let passed = familyChallengePassed {
                    familyChallengeSection(passed: passed)
                }

                Button(action: onOpenSettings) {
                    Label("Réglages (code parent)", systemImage: "lock.fill")
                        .font(ChildStyle.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .frame(minHeight: ChildStyle.minTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Réglages, protégé par code parent")
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
    }

    // MARK: - Série

    private var streakMonthCard: some View {
        let calendar = Calendar.current
        let today = CalendarDay(Date(), calendar: calendar)
        let cells = Self.monthCells(today: today,
                                    played: Gamification.playedDays(attempts: attempts, calendar: calendar),
                                    jokers: Set(jokers), calendar: calendar)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack(spacing: NotoTheme.Spacing.xs) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(streak.days > 0 ? NotoTheme.Colors.warning : NotoTheme.Colors.textTertiary)
                    .accessibilityHidden(true)
                Text(streak.days == 0
                     ? "Ta série commence avec un quiz"
                     : "Série de \(streak.days) \(streak.days == 1 ? "jour" : "jours")")
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ChildHomeView.streakAccessibilityLabel(streak))

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(["L", "M", "M", "J", "V", "S", "D"].enumerated()), id: \.offset) { _, letter in
                    Text(letter)
                        .font(ChildStyle.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .accessibilityHidden(true)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    if let cell {
                        dayCell(cell)
                    } else {
                        Color.clear.frame(height: 28)
                    }
                }
            }

            if let jokerText = ChildHomeView.jokerText(streak) {
                HStack(spacing: NotoTheme.Spacing.xs) {
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
    }

    private func dayCell(_ cell: MonthCell) -> some View {
        let fill: Color = switch cell.mark {
        case .played: NotoTheme.Colors.warning
        case .joker: NotoTheme.Colors.info.opacity(0.12)
        case .other: .clear
        }
        let text: Color = switch cell.mark {
        case .played: .white
        case .joker: NotoTheme.Colors.info
        case .other: cell.isFuture ? NotoTheme.Colors.textTertiary : NotoTheme.Colors.textSecondary
        }
        return Text("\(cell.day.day)")
            .font(ChildStyle.caption.monospacedDigit().weight(cell.mark == .other ? .regular : .semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
            .overlay {
                if cell.mark == .joker {
                    RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                        .stroke(NotoTheme.Colors.info, lineWidth: 1)
                }
            }
            .overlay {
                if cell.isToday {
                    RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                        .stroke(ChildStyle.accent, lineWidth: 2)
                }
            }
            .accessibilityLabel(Self.dayAccessibilityLabel(cell))
    }

    // MARK: - Badges

    private func badgesSection(_ child: Child) -> some View {
        let badges = GamificationStore.badges(for: child, now: Date(), calendar: .current,
                                              curriculum: CurriculumSnapshot.bundled)
        let columns = [GridItem(.flexible(), spacing: NotoTheme.Spacing.cardGap),
                       GridItem(.flexible(), spacing: NotoTheme.Spacing.cardGap)]
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text(badges.isEmpty ? "Mes badges" : "Mes badges · \(badges.count)")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)
            if badges.isEmpty {
                Text("Fais un quiz pour gagner ton premier badge.")
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(NotoTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notoCard()
            } else {
                LazyVGrid(columns: columns, spacing: NotoTheme.Spacing.cardGap) {
                    ForEach(badges) { badge in
                        HStack(spacing: NotoTheme.Spacing.sm) {
                            Image(systemName: BadgeCopy.symbol(for: badge.kind))
                                .font(.system(.title3))
                                .foregroundStyle(BadgeCopy.tint(for: badge.kind))
                                .accessibilityHidden(true)
                            Text(BadgeCopy.title(for: badge.kind))
                                .font(ChildStyle.caption.weight(.semibold))
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .notoCard()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(BadgeCopy.title(for: badge.kind)). \(BadgeCopy.detail(for: badge.kind))")
                    }
                }
            }
        }
    }

    // MARK: - Défi famille

    private func familyChallengeSection(passed: Int) -> some View {
        let goal = FamilyChallengeSettings.weeklyGoal
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Défi de la semaine en famille")
                .childSectionLabel()
                .padding(.horizontal, NotoTheme.Spacing.xs)
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                Text(ChildHomeView.familyChallengeText(passed: passed, goal: goal))
                    .font(ChildStyle.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(min(passed, goal)), total: Double(max(1, goal)))
                    .tint(ChildStyle.accent)
                    .accessibilityHidden(true)
            }
            .padding(NotoTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notoCard()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Month (pure, tested through `ChildMeCopyTests`)

    struct MonthCell: Equatable, Sendable {
        enum Mark: Sendable { case played, joker, other }
        let day: CalendarDay
        let mark: Mark
        let isToday: Bool
        let isFuture: Bool
    }

    /// `today`'s month, Monday first: nil cells pad the first week.
    static func monthCells(today: CalendarDay, played: Set<CalendarDay>, jokers: Set<CalendarDay>,
                           calendar: Calendar) -> [MonthCell?] {
        let first = CalendarDay(year: today.year, month: today.month, day: 1)
        let firstDate = first.startOfDay(in: calendar)
        let weekday = calendar.component(.weekday, from: firstDate) // 1 = Sunday
        let leading = (weekday + 5) % 7
        let count = calendar.range(of: .day, in: .month, for: firstDate)?.count ?? 30
        let days: [MonthCell?] = (1...count).map { number in
            let day = CalendarDay(year: today.year, month: today.month, day: number)
            let state: MonthCell.Mark = played.contains(day) ? .played : (jokers.contains(day) ? .joker : .other)
            return MonthCell(day: day, mark: state, isToday: day == today, isFuture: today < day)
        }
        return Array(repeating: nil, count: leading) + days
    }

    static func dayAccessibilityLabel(_ cell: MonthCell) -> String {
        let head = cell.isToday ? "Aujourd'hui, le \(cell.day.day)" : "Le \(cell.day.day)"
        switch cell.mark {
        case .played: return "\(head) : révisé"
        case .joker: return "\(head) : sauvé par un joker"
        case .other: return head
        }
    }
}
