import SwiftUI

/// Bar shown above the child app when a parent opens it from the parent app
/// (« vision enfant », `ChildHomeView(previewChild:)`). Parent tone
/// (vouvoiement): the tabs below keep the child's tutoiement, this bar and
/// the alerts are the parent's.
struct ChildPreviewBanner: View {
    let firstName: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "eye")
                .foregroundStyle(NotoTheme.Colors.cobalt)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(firstName))
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(Self.detail(firstName))
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Fermer", action: onClose)
                .font(NotoTheme.Typography.headline)
                .tint(NotoTheme.Colors.cobalt)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, NotoTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotoTheme.Colors.surface)
    }

    // MARK: - Copy (pure, tested)

    static func title(_ firstName: String) -> String {
        "Vision enfant : l'appli de \(firstName)"
    }

    /// Quiz, série, minutes and badges live on the child's device until the
    /// family sync exists (sync-famille/CADRAGE.md): say it rather than let
    /// empty cards read as « hasn't revised ».
    static func detail(_ firstName: String) -> String {
        "Lecture seule. Les quiz, la série et les minutes de \(firstName) restent sur son appareil tant que la synchro famille n'est pas activée."
    }

    static let actionTitle = "Aperçu seulement"

    static func actionMessage(_ firstName: String) -> String {
        "Dans la vision enfant, rien ne se lance ni ne s'enregistre. \(firstName) fait ses quiz sur son propre appareil."
    }

    static func entryTitle(_ firstName: String) -> String {
        "Voir l'appli de \(firstName)"
    }
}
