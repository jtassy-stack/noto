import SwiftUI
import SwiftData

/// Entry point of the "add a child" flow. Delegates to `SchoolLocatorView`,
/// which finds the establishment by geolocation and routes straight to
/// the matching login screen — `ManualProviderListView` below (the
/// previous content of this file) is the fallback for schools the
/// directory doesn't know, reached via a link at the bottom of the locator.
struct AddChildView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SchoolLocatorView(onDismissAll: { dismiss() })
    }
}

// MARK: - Manual provider list (fallback)

struct ManualProviderListView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismissAll: () -> Void

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()

            NotoLogo(size: 32)

            Text("Choisir un service")
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
                        ENTLoginView(provider: provider, onDismissAll: onDismissAll)
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

                // École Directe
                NavigationLink {
                    EcoleDirecteLoginView(onDismissAll: onDismissAll)
                } label: {
                    ServiceCard(
                        title: "École Directe",
                        subtitle: "Collège, lycée — établissements privés",
                        color: Color(hex: 0x0063A0),
                        icon: "graduationcap.fill"
                    )
                }
                .buttonStyle(.plain)

                // Skolengo
                NavigationLink {
                    SkolengoLoginView(onDismissAll: onDismissAll)
                } label: {
                    ServiceCard(
                        title: "Skolengo",
                        subtitle: "Occitanie, Auvergne-Rhône-Alpes, Grand Est, Corse et d'autres régions",
                        color: Color(hex: 0x6B4FBB),
                        icon: "building.columns.fill"
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
                Button("Annuler") { onDismissAll() }
            }
        }
    }
}

// MARK: - Service Card

struct ServiceCard: View {
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
