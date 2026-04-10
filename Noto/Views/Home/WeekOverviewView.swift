import SwiftUI

struct WeekOverviewView: View {
    let children: [Child]
    @Environment(\.dismiss) private var dismiss

    // Current week: Monday to Friday
    private var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        // Find Monday of current week
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        comps.weekday = 2 // Monday
        let monday = cal.date(from: comps) ?? today
        return (0..<5).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: NotoTheme.Spacing.md) {
                    ForEach(weekDays, id: \.self) { day in
                        DayOverviewSection(day: day, children: children)
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Cette semaine")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct DayOverviewSection: View {
    let day: Date
    let children: [Child]

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isPast: Bool { day < Calendar.current.startOfDay(for: .now) }

    private var scheduleEntries: [(child: Child, entry: ScheduleEntry)] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        return children.flatMap { child in
            child.schedule
                .filter { $0.start >= dayStart && $0.start < dayEnd }
                .map { (child: child, entry: $0) }
        }.sorted { $0.entry.start < $1.entry.start }
    }

    private var homeworkDue: [(child: Child, hw: Homework)] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        return children.flatMap { child in
            child.homework
                .filter { !$0.done && $0.dueDate >= dayStart && $0.dueDate < dayEnd }
                .map { (child: child, hw: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            // Day header
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR"))).capitalized)
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(isToday ? NotoTheme.Colors.brand : (isPast ? NotoTheme.Colors.textSecondary : NotoTheme.Colors.textPrimary))
                Text(day.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                if isToday {
                    Text("Aujourd'hui")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.brand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NotoTheme.Colors.brand.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
            }

            if scheduleEntries.isEmpty && homeworkDue.isEmpty {
                Text(isPast ? "Pas de données" : "Rien de prévu")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(.vertical, NotoTheme.Spacing.xs)
            } else {
                // Schedule entries
                ForEach(scheduleEntries, id: \.entry.id) { item in
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        Rectangle()
                            .fill(item.entry.cancelled ? NotoTheme.Colors.danger : NotoTheme.Colors.brand)
                            .frame(width: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.entry.subject)
                                    .font(NotoTheme.Typography.body)
                                    .strikethrough(item.entry.cancelled)
                                    .foregroundStyle(item.entry.cancelled ? NotoTheme.Colors.textSecondary : NotoTheme.Colors.textPrimary)
                                if children.count > 1 {
                                    Text("· \(item.child.firstName)")
                                        .font(NotoTheme.Typography.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                                if item.entry.cancelled {
                                    Text("Annulé")
                                        .font(NotoTheme.Typography.caption)
                                        .foregroundStyle(NotoTheme.Colors.danger)
                                }
                            }
                            Text("\(item.entry.start.formatted(.dateTime.hour().minute())) – \(item.entry.end.formatted(.dateTime.hour().minute()))")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.leading, NotoTheme.Spacing.xs)
                }

                // Homework due
                ForEach(homeworkDue, id: \.hw.id) { item in
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(NotoTheme.Colors.cobalt)
                            .frame(width: 16)
                        Text("**\(item.hw.subject)** — \(item.hw.descriptionText)")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                            .lineLimit(2)
                        if children.count > 1 {
                            Spacer()
                            Text(item.child.firstName)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                    .padding(.leading, NotoTheme.Spacing.xs)
                }
            }
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
        .opacity(isPast ? 0.6 : 1.0)
    }
}

#Preview("Semaine") {
    WeekOverviewView(children: [])
        .withPreviewData()
}
