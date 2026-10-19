import SwiftData
import SwiftUI

/// Parent side of family sync (phase 9.2): link the child's phone to this one
/// by sending a CloudKit invitation, check that it was accepted, unlink.
/// Shown only when `FamilySyncLink.isEnabled()` and on a parent device.
struct FamilyLinkView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let child: Child

    @State private var showUnlinkConfirm = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var state: FamilySyncLink.State {
        FamilySyncLink.state(zoneName: child.familySyncZoneName, linkedAt: child.familySyncLinkedAt)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(FamilySyncLink.parentStatus(state, firstName: child.firstName, calendar: .current))
                        .font(NotoTheme.Typography.headline)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text(FamilySyncLink.parentExplanation(firstName: child.firstName))
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }

                if let zoneName = child.familySyncZoneName {
                    Section {
                        if case .linked = state {
                            EmptyView()
                        } else {
                            ShareLink(item: FamilyShareItem(zoneName: zoneName), preview: SharePreview("nōto")) {
                                Label("Envoyer l'invitation", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Délier le téléphone de \(child.firstName)", role: .destructive) {
                            showUnlinkConfirm = true
                        }
                        .disabled(isWorking)
                    } footer: {
                        if case .linked = state {
                            EmptyView()
                        } else {
                            Text("Envoyez l'invitation par Messages ou AirDrop, puis ouvrez-la sur le téléphone de \(child.firstName).")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.danger)
                    }
                }
            }
            .navigationTitle("Relier le téléphone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog(
                "Délier le téléphone de \(child.firstName) ?",
                isPresented: $showUnlinkConfirm,
                titleVisibility: .visible
            ) {
                Button("Délier", role: .destructive) { unlink() }
                Button("Annuler", role: .cancel) { }
            } message: {
                Text("Ses résultats ne s'afficheront plus ici et vos règles ne s'appliqueront plus sur son téléphone.")
            }
            .task { await prepare() }
        }
    }

    /// Names the zone on first open (the zone and its share are created when
    /// the invitation is sent), then checks whether the child accepted.
    private func prepare() async {
        if child.familySyncZoneName == nil {
            child.familySyncZoneName = FamilySyncLink.makeZoneName()
            try? modelContext.save()
        }
        guard child.familySyncLinkedAt == nil, let zoneName = child.familySyncZoneName else { return }
        do {
            if try await FamilySyncShareService.childHasAccepted(zoneName: zoneName) {
                child.familySyncLinkedAt = .now
                try? modelContext.save()
            }
        } catch {
            NSLog("[noto][warn] family sync: checking the share failed: %@", error.localizedDescription)
        }
    }

    private func unlink() {
        guard let zoneName = child.familySyncZoneName else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await FamilySyncShareService.deleteZone(zoneName: zoneName)
                child.familySyncZoneName = nil
                child.familySyncZoneOwner = nil
                child.familySyncLinkedAt = nil
                try? modelContext.save()
                dismiss()
            } catch {
                NSLog("[noto][warn] family sync: unlinking failed: %@", error.localizedDescription)
                errorMessage = "Impossible de délier pour l'instant. Vérifiez votre connexion à iCloud et réessayez."
            }
            isWorking = false
        }
    }
}
