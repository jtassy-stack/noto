import SwiftUI

/// Sheet-presented school picker. The parent types the school name,
/// the debounced search hits `celyn.io/api/directory/schools/search`,
/// tap selects → `onSelect(result)` fires and the sheet dismisses.
///
/// No persistence happens here — the caller decides what to do with
/// the selected summary (save `rneCode` on a `Child`, prefill an
/// onboarding step, etc).
struct DirectorySchoolPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: DirectorySchoolPickerViewModel
    let onSelect: (DirectorySchoolSummary) -> Void

    init(
        client: DirectoryAPIClient = DirectoryAPIClient(),
        onSelect: @escaping (DirectorySchoolSummary) -> Void
    ) {
        // Capture `client` in the closure so the VM doesn't need to know
        // about the client type — keeps the VM easy to test with mocks.
        let search: @Sendable (String) async throws -> [DirectorySchoolSummary] = { query in
            try await client.searchSchools(q: query, limit: 30)
        }
        self._viewModel = State(wrappedValue: DirectorySchoolPickerViewModel(search: search))
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: NotoTheme.Spacing.md) {
                searchField
                content
            }
            .padding(.top, NotoTheme.Spacing.md)
            .background(NotoTheme.Colors.background)
            .navigationTitle("Rechercher un établissement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            TextField("Nom de l'école, collège, lycée…", text: $viewModel.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    Task { await viewModel.runSearchNow() }
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
        .padding(.horizontal, NotoTheme.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            idleHint
        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let schools):
            resultsList(schools)
        case .empty:
            emptyHint
        case .error(let message):
            errorHint(message)
        }
    }

    private var idleHint: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.6))
            Text("Saisissez au moins 2 caractères pour rechercher.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)
            Spacer()
        }
    }

    private var emptyHint: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Spacer()
            Text("Aucun établissement trouvé pour « \(viewModel.query) ».")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)
            Text("Vérifiez l'orthographe ou essayez un mot-clé différent (ville, numéro).")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)
            Spacer()
        }
    }

    private func errorHint(_ message: String) -> some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(NotoTheme.Colors.amber)
            Text("Recherche indisponible")
                .font(NotoTheme.Typography.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text(message)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)
            Spacer()
        }
    }

    private func resultsList(_ schools: [DirectorySchoolSummary]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(schools.enumerated()), id: \.element.id) { index, school in
                    if index > 0 {
                        Divider().padding(.leading, NotoTheme.Spacing.md)
                    }
                    Button {
                        onSelect(school)
                        dismiss()
                    } label: {
                        schoolRow(school)
                    }
                    .buttonStyle(.plain)
                }
            }
            .notoCard()
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.bottom, NotoTheme.Spacing.md)
        }
    }

    private func schoolRow(_ school: DirectorySchoolSummary) -> some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(school.name)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if let kind = school.kind { Text(kind.capitalized) }
                    if let academy = school.academy {
                        Text("·")
                        Text(academy)
                    }
                    Text("·")
                    Text(school.rne)
                        .monospaced()
                }
                .font(NotoTheme.Typography.metadata)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .opacity(0.65)
                .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .opacity(0.5)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
    }
}
