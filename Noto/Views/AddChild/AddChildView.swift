import SwiftUI
import SwiftData

struct AddChildView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var selectedType: SchoolType?

    var body: some View {
        NavigationStack {
            VStack(spacing: NotoTheme.Spacing.xl) {
                Spacer()

                Text("Ajouter un enfant")
                    .font(NotoTheme.Typography.title)

                Text("Choisissez le service utilisé par l'établissement de votre enfant.")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NotoTheme.Spacing.xl)

                Spacer()

                VStack(spacing: NotoTheme.Spacing.md) {
                    NavigationLink {
                        PronoteQRLoginView()
                    } label: {
                        ServiceCard(
                            title: "Pronote",
                            subtitle: "Collège, lycée — scannez le QR code depuis l'app Pronote",
                            color: NotoTheme.Colors.pronote,
                            icon: "qrcode"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ENTLoginView()
                    } label: {
                        ServiceCard(
                            title: "ENT / Paris Classe Numérique",
                            subtitle: "Élémentaire, maternelle — cahier de liaison, blog, messagerie",
                            color: NotoTheme.Colors.ent,
                            icon: "building.columns"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Service Card

private struct ServiceCard: View {
    let title: String
    let subtitle: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                Text(title)
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(NotoTheme.Spacing.md)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
    }
}
