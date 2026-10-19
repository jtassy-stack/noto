import SwiftUI
import SwiftData

/// Parent « Écran » tab, per child: the bonus minutes earned today against the
/// daily cap (ring), the last 7 days (bars, dashed cap line), the class hours
/// the lock covers (0–24 h strip) and the barème, with the full Temps d'écran
/// and Révisions settings one tap away. Parent tone (vouvoiement).
///
/// nōto reads no app usage: this screen shows minutes earned, never time
/// spent. Quizzes and the reward rules live on the device where the child
/// plays; on the parent's device they arrive with the family sync when the
/// child's phone is linked (phase 9.3), otherwise the minute cards say so.
struct ScreenOverviewView: View {
    @Query private var families: [Family]
    @State private var selectedChildID: PersistentIdentifier?
    @State private var config = RewardConfigStore.load()
    @State private var showRewardSettings = false
    @State private var showScreenTimeSettings = false

    private var children: [Child] { families.first?.children ?? [] }

    private var child: Child? {
        children.first { $0.persistentModelID == selectedChildID } ?? children.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.cardGap) {
                    Text("Temps d'écran")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)

                    if children.count > 1 {
                        childPicker
                    }

                    if let child {
                        content(child)
                    } else {
                        Text("Ajoutez d'abord un enfant dans les réglages.")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .padding(NotoTheme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .notoCard()
                    }

                    settingsCard
                }
                .padding(NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { config = RewardConfigStore.load() }
            .sheet(isPresented: $showRewardSettings, onDismiss: { config = RewardConfigStore.load() }) {
                RevisionSettingsView()
            }
            .sheet(isPresented: $showScreenTimeSettings) {
                ScreenTimeView()
            }
        }
    }

    private var childPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                ForEach(children) { option in
                    let active = option.persistentModelID == child?.persistentModelID
                    Button {
                        selectedChildID = option.persistentModelID
                    } label: {
                        Text("\(option.firstName) · \(option.grade)")
                            .font(NotoTheme.Typography.body.weight(active ? .semibold : .medium))
                            .foregroundStyle(active ? Color.white : NotoTheme.Colors.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(active ? NotoTheme.Colors.brand : NotoTheme.Colors.surface,
                                        in: RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                                    .stroke(active ? Color.clear : NotoTheme.Colors.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Per child

    @ViewBuilder
    private func content(_ child: Child) -> some View {
        let now = Date()
        let calendar = Calendar.current
        let summary = RevisionReportStore.summary(for: child, now: now, calendar: calendar)
        let span = ScreenOverviewReport.classSpan(
            lessons: child.schedule.map {
                ScreenOverviewReport.Lesson(start: $0.start, end: $0.end, cancelled: $0.cancelled)
            },
            now: now, calendar: calendar)

        if summary.isActive {
            todayCard(earned: summary.minutesEarnedToday)
            weekCard(ScreenOverviewReport.earnedPerDay(attempts: GamificationStore.attempts(of: child),
                                                       now: now, calendar: calendar))
            if child.receivesFamilySync {
                syncedCaption(child, now: now, calendar: calendar)
            }
        } else {
            Text(child.receivesFamilySync
                 ? FamilySyncLink.waitingMinutesText(firstName: child.firstName)
                 : "Les minutes gagnées par \(child.firstName) s'affichent sur l'appareil où \(child.firstName) "
                    + "fait ses quiz.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .padding(NotoTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notoCard()
        }

        if let span {
            lockCard(span, now: now, calendar: calendar)
        }
    }

    /// Linked: when the figures last came from the child's phone, and the
    /// minutes it keeps in reserve during class.
    private func syncedCaption(_ child: Child, now: Date, calendar: Calendar) -> some View {
        let reserve = child.familySyncZoneName.flatMap { FamilySyncStateStore().receivedMinutes(zoneName: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            if let line = FamilySyncLink.reserveText(reserve, now: now, calendar: calendar) {
                Text(line)
            }
            Label(FamilySyncLink.syncedText(child.familySyncLastSyncedAt, now: now, calendar: calendar)
                      + " avec le téléphone de \(child.firstName)",
                  systemImage: "arrow.triangle.2.circlepath")
        }
        .font(NotoTheme.Typography.caption)
        .foregroundStyle(NotoTheme.Colors.textSecondary)
        .padding(.horizontal, NotoTheme.Spacing.xs)
    }

    private func todayCard(earned: Int) -> some View {
        let cap = config.dailyCap
        let fraction = cap > 0 ? min(1, Double(earned) / Double(cap)) : 0
        return HStack(spacing: NotoTheme.Spacing.md) {
            ZStack {
                Circle().stroke(NotoTheme.Colors.surfaceSecondary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(NotoTheme.Colors.brand, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(earned)")
                        .font(NotoTheme.Typography.dataLarge)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text("min")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bonus du jour").sectionLabelStyle()
                Text(ScreenOverviewReport.todayLine(earned: earned, cap: cap))
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    private func weekCard(_ days: [ScreenOverviewReport.DayMinutes]) -> some View {
        let cap = config.dailyCap
        let top = max(cap, days.map(\.minutes).max() ?? 0, 1)
        let chartHeight: CGFloat = 96
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("7 derniers jours").sectionLabelStyle()
                Spacer()
                if let average = ScreenOverviewReport.averageEarned(days) {
                    Text("bonus moyen \(average) min")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            ZStack(alignment: .bottom) {
                if cap > 0 {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HorizontalLine()
                            .stroke(NotoTheme.Colors.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(height: 1)
                        Color.clear.frame(height: chartHeight * CGFloat(cap) / CGFloat(top))
                    }
                }
                HStack(alignment: .bottom, spacing: NotoTheme.Spacing.sm) {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.minutes > 0 ? NotoTheme.Colors.brand : NotoTheme.Colors.surfaceSecondary)
                            .frame(height: max(4, chartHeight * CGFloat(day.minutes) / CGFloat(top)))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(days.map { "\($0.letter) \($0.minutes) min" }.joined(separator: ", "))

            HStack(spacing: NotoTheme.Spacing.sm) {
                ForEach(days) { day in
                    Text(day.letter)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(NotoTheme.Typography.caption)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .accessibilityHidden(true)

            if cap > 0 {
                Text("Pointillés : plafond de \(cap) min")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    private func lockCard(_ span: ScreenOverviewReport.ClassSpan, now: Date, calendar: Calendar) -> some View {
        let day = 24.0 * 60
        return VStack(alignment: .leading, spacing: 10) {
            Text("Heures de cours · \(ScreenOverviewReport.dayLabel(span.day, now: now, calendar: calendar))")
                .sectionLabelStyle()
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(NotoTheme.Colors.surfaceSecondary)
                    Capsule()
                        .fill(NotoTheme.Colors.brand)
                        .frame(width: max(6, width * CGFloat(Double(span.endMinutes - span.startMinutes) / day)))
                        .offset(x: width * CGFloat(Double(span.startMinutes) / day))
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            HStack {
                Text("0 h")
                Spacer()
                Text("\(ScreenOverviewReport.clockText(span.startMinutes)) – "
                     + "\(ScreenOverviewReport.clockText(span.endMinutes))")
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Spacer()
                Text("24 h")
            }
            .font(NotoTheme.Typography.caption.monospacedDigit())
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            Text("Les cours restent verrouillés, même avec du temps bonus.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notoCard()
    }

    // MARK: - Réglages

    private var settingsCard: some View {
        VStack(spacing: 0) {
            settingsRow(title: "Barème des quiz", value: ScreenOverviewReport.tiersText(config.tiers)) {
                showRewardSettings = true
            }
            SettingsDivider()
            settingsRow(title: "Plafond du bonus", value: "\(config.dailyCap) min") {
                showRewardSettings = true
            }
            SettingsDivider()
            settingsRow(title: "Apps et verrou des cours", value: nil) {
                showScreenTimeSettings = true
            }
        }
        .notoCard()
    }

    private func settingsRow(title: String, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Spacer()
                if let value {
                    Text(value)
                        .font(NotoTheme.Typography.body.monospacedDigit())
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal line across the frame, for the dashed cap.
private struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
