import SwiftUI
import SwiftData

/// One-tap diagnostic: re-authenticates and runs a single lightweight
/// read call against each configured school connection, reporting
/// success/latency or the exact failure reason per child. Read-only —
/// no data is synced or written; it exists to separate "my Pronote
/// password expired" from "nōto can't reach Pronote" from "the API
/// changed shape", instead of a parent guessing from a generic
/// "sync échouée" banner.
struct ConnectionHealthcheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var isRunning = false
    @State private var results: [ConnectionCheckResult] = []
    @State private var hasRun = false

    private var children: [Child] { families.first?.children ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                    Text("Vérifie que chaque connexion école répond, sans synchroniser de données.")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)

                    if isRunning {
                        HStack(spacing: NotoTheme.Spacing.sm) {
                            ProgressView()
                            Text("Vérification en cours…")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        .padding(.vertical, NotoTheme.Spacing.md)
                    } else if hasRun {
                        resultsList
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Diagnostic de connexion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(hasRun ? "Relancer" : "Lancer") {
                        Task { await runCheck() }
                    }
                    .disabled(isRunning || children.isEmpty)
                }
            }
            .task {
                if !hasRun { await runCheck() }
            }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 1) {
            if results.isEmpty {
                Text("Aucun enfant connecté à vérifier.")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(NotoTheme.Spacing.md)
            } else {
                ForEach(results) { result in
                    resultRow(result)
                }
            }
        }
        .notoCard()
    }

    private func resultRow(_ result: ConnectionCheckResult) -> some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            statusIcon(result.status)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(result.childName) · \(result.connectionLabel)")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                switch result.status {
                case .ok(let latencyMs):
                    Text("OK — \(latencyMs) ms")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                case .failed(let message):
                    Text(message)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.danger)
                }
            }
            Spacer()
        }
        .padding(NotoTheme.Spacing.sm)
    }

    @ViewBuilder
    private func statusIcon(_ status: ConnectionCheckResult.Status) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(NotoTheme.Colors.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(NotoTheme.Colors.danger)
        }
    }

    private func runCheck() async {
        isRunning = true
        results = await ConnectionHealthcheckService.run(children: children, modelContext: modelContext)
        isRunning = false
        hasRun = true
    }
}
