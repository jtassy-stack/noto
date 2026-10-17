import SwiftUI

/// Texte venant de l'école avec URL et e-mails cliquables.
///
/// Garde la police et la sélection posées par l'appelant (`.font`,
/// `.textSelection`) ; les liens prennent la teinte « liens » du thème.
/// Un tap ouvre le navigateur (ou Mail pour `mailto:`) via l'action système ;
/// tout schéma hors liste blanche est ignoré par défense en profondeur.
struct LinkifiedText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LinkDetector.attributed(text))
            .tint(NotoTheme.Colors.cobalt)
            .environment(\.openURL, OpenURLAction { url in
                LinkDetector.isAllowed(url) ? .systemAction : .discarded
            })
    }
}
