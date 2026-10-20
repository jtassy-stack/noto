import SwiftUI

/// Chronological 48-hour timeline aggregating schedule entries and
/// homework across all children. Grouped by day with separators.
/// Follows the neutral card style (`.notoCard()`, no signal tint).
struct TimelineView: View {
    let children: [Child]

    private var timelineItems: [(day: String, items: [TimelineItem])] {
        let now = Date.now
        let calendar = Calendar.current
        let in48h = now.addingTimeInterval(48 * 3600)

        var allItems: [TimelineItem] = []

        for child in children {
            // Schedule entries
            for entry in child.schedule where entry.start >= now && entry.start <= in48h {
                let time = entry.start.formatted(
                    .dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))
                )
                let label = entry.cancelled
                    ? "\(child.firstName) · \(entry.subject) \(time) — annulé"
                    : "\(child.firstName) · \(entry.subject) \(time)"
                allItems.append(TimelineItem(
                    date: entry.start,
                    label: label,
                    isCancelled: entry.cancelled,
                    childName: child.firstName
                ))
            }

            // Homework due
            for hw in child.homework where !hw.done && hw.dueDate >= now && hw.dueDate <= in48h {
                allItems.append(TimelineItem(
                    date: hw.dueDate,
                    label: "\(child.firstName) · Devoir \(hw.subject)",
                    isCancelled: false,
                    childName: child.firstName
                ))
            }
        }

        allItems.sort { $0.date < $1.date }

        // Group by day
        let grouped = Dictionary(grouping: allItems) { item -> String in
            if calendar.isDateInToday(item.date) { return "Aujourd'hui" }
            if calendar.isDateInTomorrow(item.date) { return "Demain" }
            let df = DateFormatter()
            df.locale = Locale(identifier: "fr_FR")
            df.dateFormat = "EEE d"
            return df.string(from: item.date).capitalized
        }

        // Sort groups chronologically
        let sortedKeys = grouped.keys.sorted { a, b in
            let dateA = grouped[a]!.first!.date
            let dateB = grouped[b]!.first!.date
            return dateA < dateB
        }

        return sortedKeys.map { key in (day: key, items: grouped[key]!) }
    }

    /// First non-cancelled lesson after the 48 h window (e.g. the day classes
    /// resume after the holidays), so an empty timeline still says when the
    /// next class is instead of leaving the section blank.
    private var nextLessonAfterWindow: Date? {
        Self.nextLessonStart(
            after: Date.now.addingTimeInterval(48 * 3600),
            lessons: children.flatMap { $0.schedule }.map { (start: $0.start, cancelled: $0.cancelled) }
        )
    }

    static func nextLessonStart(after date: Date, lessons: [(start: Date, cancelled: Bool)]) -> Date? {
        lessons.filter { !$0.cancelled && $0.start > date }.map(\.start).min()
    }

    static func emptyText(nextLesson: Date?) -> String {
        guard let nextLesson else { return "Aucun cours ni devoir d'ici 48 h." }
        let day = nextLesson.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))
        )
        return "Aucun cours d'ici 48 h. Prochain cours : \(day)."
    }

    var body: some View {
        if timelineItems.isEmpty {
            return AnyView(
                Text(Self.emptyText(nextLesson: nextLessonAfterWindow))
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .notoCard()
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                ForEach(Array(timelineItems.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                            .background(NotoTheme.Colors.border)
                    }

                    HStack(alignment: .top, spacing: NotoTheme.Spacing.cardGap) {
                        Text(group.day)
                            .font(NotoTheme.Typography.functional(12, weight: .semibold))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .frame(width: 56, alignment: .leading)

                        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                Text(item.label)
                                    .font(NotoTheme.Typography.metadata)
                                    .foregroundStyle(
                                        item.isCancelled
                                            ? NotoTheme.Colors.danger
                                            : NotoTheme.Colors.textPrimary
                                    )
                                    .strikethrough(item.isCancelled)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .notoCard()
        )
    }
}

private struct TimelineItem {
    let date: Date
    let label: String
    let isCancelled: Bool
    let childName: String
}
