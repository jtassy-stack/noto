import SwiftUI
import SwiftData

struct AddChildView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    var body: some View {
        NavigationStack {
            VStack(spacing: NotoTheme.Spacing.xl) {
                Spacer()

                NotoLogo(size: 32)

                Text("Ajouter un enfant")
                    .font(NotoTheme.Typography.title)

                Text("Choisissez le service utilisé par l'établissement de votre enfant.")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NotoTheme.Spacing.xl)

                Spacer()

                VStack(spacing: NotoTheme.Spacing.md) {
                    // Pronote
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

                    // ENT providers
                    ForEach(ENTProvider.allCases) { provider in
                        NavigationLink {
                            ENTLoginView(provider: provider, onDismissAll: { dismiss() })
                        } label: {
                            ServiceCard(
                                title: provider.name,
                                subtitle: provider.subtitle,
                                color: Color(hex: UInt(provider.color.dropFirst(), radix: 16) ?? 0x2563EB),
                                icon: provider.icon
                            )
                        }
                        .buttonStyle(.plain)
                    }
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
