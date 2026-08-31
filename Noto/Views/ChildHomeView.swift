import SwiftUI
import SwiftData

/// Minimal child-facing screen for devices set to `DeviceMode.child` —
/// today's schedule and the current Screen Time status, read-only. Parent
/// controls (restrictions, thresholds, class-lock setup) stay in
/// `ScreenTimeView`/Settings, which remain reachable — this is a first,
/// deliberately narrow increment (see conversation scoping), not a full
/// child/parent split of every screen.
struct ChildHomeView: View {
    @Query private var families: [Family]
    @ObservedObject private var screenTimeManager = ScreenTimeManager.shared
    @State private var showParentGate = false
    @State private var gateApproved = false
    @State private var showSettings = false

    private var child: Child? {
        guard let linkedID = ScreenTimeEventStore.loadLinkedChildID() else {
            return families.first?.children.first
        }
        return families.first?.children.first(where: { "\($0.id)" == linkedID }) ?? families.first?.children.first
    }

    private var todaysLessons: [ScheduleEntry] {
        guard let child else { return [] }
        return child.schedule
            .filter { Calendar.current.isDateInToday($0.start) && !$0.cancelled }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    Text(greeting)
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)

                    scheduleSection
                    screenTimeStatusSection
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // No PIN configured yet (e.g. upgraded from before
                        // this feature existed) — fail open rather than
                        // permanently locking Settings out of reach.
                        if ParentGateService.isConfigured {
                            showParentGate = true
                        } else {
                            showSettings = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Réglages — protégé par code parent")
                }
            }
            // Réglages (restrictions, déconnexion des comptes, etc.) est un
            // écran parent — un enfant qui tient ce téléphone ne doit pas
            // pouvoir désactiver son propre contrôle parental d'un tap.
            .sheet(isPresented: $showParentGate, onDismiss: {
                if gateApproved {
                    gateApproved = false
                    showSettings = true
                }
            }) {
                ParentGateView(mode: .verify) { success in gateApproved = success }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .onAppear {
            screenTimeManager.refresh()
        }
    }

    private var greeting: String {
        guard let child else { return "Bonjour" }
        return "Salut \(child.firstName)"
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Aujourd'hui")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            if todaysLessons.isEmpty {
                Text("Pas de cours aujourd'hui.")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(NotoTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notoCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(todaysLessons.enumerated()), id: \.element.id) { index, lesson in
                        if index > 0 { SettingsDivider() }
                        HStack(spacing: NotoTheme.Spacing.md) {
                            Text(lesson.start.formatted(.dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))))
                                .font(NotoTheme.Typography.data)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .frame(width: 48, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.subject)
                                    .font(NotoTheme.Typography.body)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                if let room = lesson.room {
                                    Text(room)
                                        .font(NotoTheme.Typography.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 12)
                    }
                }
                .notoCard()
            }
        }
    }

    private var screenTimeStatusSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Temps d'écran")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            HStack {
                Image(systemName: screenTimeManager.isAuthorized ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(screenTimeManager.isAuthorized ? NotoTheme.Colors.success : NotoTheme.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(screenTimeManager.isAuthorized ? "Contrôle actif" : "Contrôle non configuré")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    if ScreenTimeEventStore.isClassLockEnabled() {
                        Text("Verrouillage pendant les cours activé")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(NotoTheme.Spacing.md)
            .notoCard()
        }
    }
}
