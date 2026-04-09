import SwiftUI
import SwiftData

// MARK: - View State

private enum AbsenceViewState: Equatable {
    case idle
    case loadingRecipients
    case ready([String])            // recipient display names
    case sending
    case sent
    case error(String)

    static func == (lhs: AbsenceViewState, rhs: AbsenceViewState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loadingRecipients, .loadingRecipients),
             (.sending, .sending), (.sent, .sent): return true
        case (.ready(let a), .ready(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - AbsenceView

struct AbsenceView: View {
    // Injected
    var preselectedChild: Child?
    @Environment(\.modelContext) private var modelContext

    // Dismiss
    @Environment(\.dismiss) private var dismiss

    // SwiftData query for child picker
    @Query(sort: \Child.firstName) private var allChildren: [Child]

    // Form state
    @State private var selectedChild: Child?
    @State private var dateMode: DateMode = .today
    @State private var customDate: Date = Date()
    @State private var motif: AbsenceMotif = .maladie
    @State private var motifDetail: String = ""
    @State private var viewState: AbsenceViewState = .idle
    @State private var resolvedRecipients: [AbsenceRecipient] = []
    @State private var showConfirm = false
    @State private var parentName: String = ""

    // Service
    private let service = AbsenceService()

    private enum DateMode: Equatable {
        case today, tomorrow, custom
        var label: String {
            switch self {
            case .today:    return "Aujourd'hui"
            case .tomorrow: return "Demain"
            case .custom:   return "Autre date"
            }
        }
    }

    // MARK: - Computed

    private var activeChild: Child? {
        selectedChild ?? preselectedChild
    }

    private var selectedDate: Date {
        switch dateMode {
        case .today:    return Calendar.current.startOfDay(for: Date())
        case .tomorrow: return Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        case .custom:   return Calendar.current.startOfDay(for: customDate)
        }
    }

    private var entChildren: [Child] {
        allChildren.filter { $0.schoolType == .ent }
    }

    private var recipientNames: [String] {
        if case .ready(let names) = viewState { return names }
        return resolvedRecipients.map(\.displayName)
    }

    private var recipientSummary: String {
        recipientNames.joined(separator: ", ")
    }

    private var messageSubject: String {
        guard let child = activeChild else { return "" }
        let className = child.entClassName ?? child.grade
        return "Absence de \(child.firstName) - \(className) - \(shortDate(selectedDate))"
    }

    private var messageBodyPreview: String {
        guard let child = activeChild else { return "" }
        let className = child.entClassName ?? child.grade
        let motifText = (motif == .autre && !motifDetail.trimmingCharacters(in: .whitespaces).isEmpty)
            ? motifDetail.trimmingCharacters(in: .whitespaces)
            : motif.label
        return "Madame, Monsieur,\n\nJe vous informe que mon enfant \(child.firstName), en classe de \(className), sera absent(e) le \(longDate(selectedDate)).\n\nMotif : \(motifText)"
    }

    private var canSend: Bool {
        guard let child = activeChild, child.schoolType == .ent else { return false }
        if motif == .autre && motifDetail.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if case .sending = viewState { return false }
        if case .sent = viewState { return false }
        return !resolvedRecipients.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {

                    // Child section
                    childSection

                    if let child = activeChild {
                        if child.schoolType == .pronote {
                            pronoteUnavailable
                        } else {
                            dateSection
                            motifSection
                            previewSection
                            recipientsSection
                            sendSection
                        }
                    }

                    Spacer(minLength: NotoTheme.Spacing.xl)
                }
                .padding(NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Signaler une absence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            .alert("Confirmer l'envoi", isPresented: $showConfirm) {
                Button("Annuler", role: .cancel) {}
                Button("Envoyer") { Task { await send() } }
            } message: {
                Text("Voulez-vous envoyer ce message à \(recipientSummary)\u{00A0}?")
            }
        }
        .onAppear {
            selectedChild = preselectedChild ?? entChildren.first
            loadParentName()
            Task { await resolveRecipients() }
        }
        .onChange(of: activeChild?.id) { _, _ in
            resolvedRecipients = []
            viewState = .idle
            Task { await resolveRecipients() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var childSection: some View {
        if entChildren.count > 1 {
            // Multi-child picker
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                sectionLabel("ENFANT")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        ForEach(entChildren) { child in
                            childChip(child)
                        }
                    }
                }
            }
        } else if let child = activeChild {
            // Single child card
            VStack(alignment: .leading, spacing: 4) {
                Text(child.firstName)
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(child.entClassName ?? child.grade)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NotoTheme.Spacing.md)
            .notoCard()
        }
    }

    private func childChip(_ child: Child) -> some View {
        Button {
            selectedChild = child
        } label: {
            Text(child.firstName)
                .font(NotoTheme.Typography.caption)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm)
                .background(activeChild?.id == child.id ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                .foregroundStyle(activeChild?.id == child.id ? NotoTheme.Colors.shadow : NotoTheme.Colors.textPrimary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(NotoTheme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var pronoteUnavailable: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(NotoTheme.Colors.textTertiary)
            Text("Non disponible pour les comptes Pronote")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Text("Le signalement d'absence est uniquement disponible pour les comptes ENT (Paris Classe Numérique, MonLycée.net).")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(NotoTheme.Spacing.lg)
        .notoCard()
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionLabel("DATE")
            HStack(spacing: NotoTheme.Spacing.sm) {
                ForEach([DateMode.today, .tomorrow, .custom], id: \.label) { mode in
                    dateButton(mode)
                }
            }
            if dateMode == .custom {
                DatePicker(
                    "",
                    selection: $customDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .colorScheme(.dark)
                .padding(.top, NotoTheme.Spacing.xs)
            }
        }
    }

    private func dateButton(_ mode: DateMode) -> some View {
        let active = dateMode == mode
        return Button { dateMode = mode } label: {
            Text(mode.label)
                .font(NotoTheme.Typography.caption)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(active ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                .foregroundStyle(active ? NotoTheme.Colors.shadow : NotoTheme.Colors.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.pill))
                .overlay(
                    RoundedRectangle(cornerRadius: NotoTheme.Radius.pill)
                        .stroke(active ? Color.clear : NotoTheme.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var motifSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionLabel("MOTIF")
            FlowLayout(spacing: NotoTheme.Spacing.sm) {
                ForEach(AbsenceMotif.allCases, id: \.rawValue) { m in
                    motifButton(m)
                }
            }
            if motif == .autre {
                TextField("Précisez le motif...", text: $motifDetail, axis: .vertical)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .padding(NotoTheme.Spacing.md)
                    .background(NotoTheme.Colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: NotoTheme.Radius.md)
                            .stroke(NotoTheme.Colors.border, lineWidth: 1)
                    )
                    .lineLimit(2...4)
            }
        }
    }

    private func motifButton(_ m: AbsenceMotif) -> some View {
        let active = motif == m
        return Button { motif = m } label: {
            Text(m.label)
                .font(NotoTheme.Typography.caption)
                .padding(.vertical, 10)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .background(active ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                .foregroundStyle(active ? NotoTheme.Colors.shadow : NotoTheme.Colors.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.pill))
                .overlay(
                    RoundedRectangle(cornerRadius: NotoTheme.Radius.pill)
                        .stroke(active ? Color.clear : NotoTheme.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionLabel("APERÇU")
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                Text(messageSubject)
                    .font(NotoTheme.Typography.body.weight(.bold))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .lineLimit(2)

                Divider().background(NotoTheme.Colors.border)

                Text(messageBodyPreview)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(6)

                if !recipientNames.isEmpty {
                    Text("→ \(recipientSummary)")
                        .font(NotoTheme.Typography.dataSmall)
                        .foregroundStyle(NotoTheme.Colors.textTertiary)
                        .lineLimit(2)
                }
            }
            .padding(NotoTheme.Spacing.md)
            .notoCard()
        }
    }

    @ViewBuilder
    private var recipientsSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionLabel("DESTINATAIRES")
            switch viewState {
            case .loadingRecipients:
                HStack(spacing: NotoTheme.Spacing.sm) {
                    ProgressView()
                        .tint(NotoTheme.Colors.textSecondary)
                    Text("Chargement des destinataires...")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .padding(NotoTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notoCard()

            case .error(let msg):
                HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(NotoTheme.Colors.danger)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(msg)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.danger)
                        Button("Réessayer") {
                            Task { await resolveRecipients() }
                        }
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.brand)
                    }
                }
                .padding(NotoTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notoCard()

            default:
                if resolvedRecipients.isEmpty {
                    Text("Aucun destinataire trouvé")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textTertiary)
                        .padding(NotoTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .notoCard()
                } else {
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                        ForEach(resolvedRecipients) { r in
                            HStack(spacing: NotoTheme.Spacing.sm) {
                                Image(systemName: r.isGroup ? "person.2" : "person")
                                    .font(.system(size: 12))
                                    .foregroundStyle(NotoTheme.Colors.textTertiary)
                                Text(r.displayName)
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(NotoTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notoCard()
                }
            }
        }
    }

    @ViewBuilder
    private var sendSection: some View {
        switch viewState {
        case .sent:
            VStack(spacing: NotoTheme.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(NotoTheme.Colors.brand)
                Text("Absence signalée")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text("Le message a été envoyé.")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Button("Fermer") { dismiss() }
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.brand)
                    .padding(.top, NotoTheme.Spacing.sm)
            }
            .frame(maxWidth: .infinity)
            .padding(NotoTheme.Spacing.lg)

        case .sending:
            HStack {
                ProgressView()
                    .tint(NotoTheme.Colors.shadow)
                Text("Envoi en cours...")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.shadow)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NotoTheme.Spacing.md)
            .background(NotoTheme.Colors.brand.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))

        default:
            Button {
                guard canSend else { return }
                showConfirm = true
            } label: {
                Text("Envoyer l'absence")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(canSend ? NotoTheme.Colors.shadow : NotoTheme.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NotoTheme.Spacing.md)
                    .background(canSend ? NotoTheme.Colors.brand : NotoTheme.Colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: NotoTheme.Radius.md)
                            .stroke(canSend ? Color.clear : NotoTheme.Colors.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .kerning(1.5)
            .foregroundStyle(NotoTheme.Colors.textTertiary)
    }

    // MARK: - Actions

    @MainActor
    private func resolveRecipients() async {
        guard let child = activeChild, child.schoolType == .ent else { return }
        viewState = .loadingRecipients

        do {
            let client = try await service.getOrRefreshClient(for: child)
            let found = try await service.findRecipients(for: child, client: client)
            resolvedRecipients = found
            viewState = found.isEmpty ? .error("Aucun destinataire trouvé") : .ready(found.map(\.displayName))
        } catch {
            resolvedRecipients = []
            viewState = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func send() async {
        guard let child = activeChild, canSend else { return }
        viewState = .sending

        do {
            let client = try await service.getOrRefreshClient(for: child)
            try await service.sendAbsence(
                child: child,
                date: selectedDate,
                dateEnd: nil,
                motif: motif,
                motifDetail: motif == .autre ? motifDetail : nil,
                parentName: parentName,
                client: client
            )
            viewState = .sent
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func loadParentName() {
        let descriptor = FetchDescriptor<Family>()
        parentName = (try? modelContext.fetch(descriptor).first?.parentName) ?? ""
    }

    // MARK: - Date Formatters

    private func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM yyyy"
        return f.string(from: date)
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .short
        return f.string(from: date)
    }
}

// MARK: - FlowLayout (wrapping HStack)

/// A simple left-to-right wrapping layout for pill grids.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
