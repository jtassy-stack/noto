import SwiftUI

/// Sheet shown when the parent taps a wellbeing signal card, and
/// also reachable on-demand from the Accompagner tab. Strictly a list
/// of curated French resources — no scoring, no questionnaire, no
/// in-app intervention. Links out via `tel:` and the national public
/// resource pages so the call always goes to a qualified human.
///
/// Resource tiers:
///   - **En première intention** — école des parents, infirmière
///     scolaire, médecin traitant. What most parents actually need
///     when "something seems off".
///   - **Pour un adolescent** — Fil Santé Jeunes, Maisons des Adolescents.
///     National hotlines specifically scoped to teens.
///   - **En cas de crise** — 3114. Kept visible but at the bottom so
///     it doesn't dominate a gentle-signal context.
struct WellbeingResourcesView: View {
    @Environment(\.dismiss) private var dismiss
    let signal: WellbeingSignal?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    if let signal {
                        summaryCard(signal)
                    }
                    disclaimer
                    firstTier
                    if showsTeenResources { teenTier }
                    crisisTier
                    footnote
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Accompagner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private func summaryCard(_ signal: WellbeingSignal) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Observé pour \(signal.childName)")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            ForEach(Array(signal.factors.enumerated()), id: \.offset) { _, factor in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(NotoTheme.Colors.amber)
                        .padding(.top, 7)
                    Text(factor.detail)
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                }
            }
        }
        .padding(NotoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotoTheme.Colors.amber.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: NotoTheme.Radius.card)
                .stroke(NotoTheme.Colors.amber.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
    }

    private var showsTeenResources: Bool {
        guard let signal else { return true }
        return signal.childLevel == .college || signal.childLevel == .lycee
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            Text("Ces signaux sont des observations, pas un diagnostic. Une période difficile passe souvent avec un peu d'attention et d'écoute. Si le malaise persiste ou s'aggrave, les ressources ci-dessous peuvent aider.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
    }

    private var firstTier: some View {
        section(title: "EN PREMIÈRE INTENTION") {
            resourceRow(
                title: "École des Parents et des Éducateurs",
                subtitle: "01 44 93 44 88 · Écoute & conseil aux parents",
                tel: "0144934488"
            )
            resourceRow(
                title: "Infirmière scolaire / médecin scolaire",
                subtitle: "Contact via l'établissement",
                tel: nil
            )
            resourceRow(
                title: "Médecin traitant",
                subtitle: "Premier interlocuteur en cas d'inquiétude durable",
                tel: nil
            )
        }
    }

    private var teenTier: some View {
        section(title: "POUR UN ADOLESCENT") {
            resourceRow(
                title: "Fil Santé Jeunes",
                subtitle: "0 800 235 236 · Anonyme & gratuit · 9h-23h",
                tel: "0800235236"
            )
            resourceRow(
                title: "Maisons des Adolescents",
                subtitle: "Accueil pluridisciplinaire sans rendez-vous",
                link: URL(string: "https://anmda.fr/carte")
            )
        }
    }

    private var crisisTier: some View {
        section(title: "EN CAS DE CRISE") {
            resourceRow(
                title: "3114 — Numéro national de prévention du suicide",
                subtitle: "24h/24 · 7j/7 · Gratuit & confidentiel",
                tel: "3114",
                accent: .urgent
            )
        }
    }

    private var footnote: some View {
        Text("nōto ne stocke ni ne transmet ces signaux. Ils sont recalculés à chaque ouverture, à partir de ce que vous avez déjà sur votre téléphone.")
            .font(NotoTheme.Typography.caption)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .multilineTextAlignment(.leading)
            .padding(.top, NotoTheme.Spacing.sm)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text(title)
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)
            VStack(spacing: 0) { content() }
                .notoCard()
        }
    }

    private enum RowAccent { case normal, urgent }

    @ViewBuilder
    private func resourceRow(
        title: String,
        subtitle: String,
        tel: String? = nil,
        link: URL? = nil,
        accent: RowAccent = .normal
    ) -> some View {
        let destination: URL? = {
            if let tel {
                let url = URL(string: "tel:\(tel)")
                assert(url != nil, "WellbeingResourcesView: tel: URL construction failed for '\(tel)'")
                return url
            }
            return link
        }()
        let row = HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(accent == .urgent ? NotoTheme.Colors.crimson : NotoTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
            if destination != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.5)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)

        if let destination {
            Link(destination: destination) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}
