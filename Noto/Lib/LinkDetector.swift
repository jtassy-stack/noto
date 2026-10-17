import Foundation

/// Détecte les URL et adresses e-mail dans un texte venant de l'école
/// (devoirs, messages, actualités) et les rend cliquables.
///
/// Logique pure, sans SwiftUI : la vue applique la police et la teinte du
/// thème (`NotoTheme.Colors.cobalt`). Détection 100 % sur l'appareil via
/// `NSDataDetector`, aucun appel réseau.
///
/// Le contenu est tiers (saisi par les enseignants) : seuls `http`, `https`
/// et `mailto` sont autorisés. `javascript:`, `data:`, `tel:`, schémas
/// d'apps… restent du texte inerte.
enum LinkDetector {

    struct DetectedLink: Equatable {
        let url: URL
        let range: Range<String.Index>
    }

    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Liens autorisés trouvés dans `text`, dans l'ordre d'apparition.
    static func links(in text: String) -> [DetectedLink] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let url = match.url,
                  isAllowed(url),
                  let range = Range(match.range, in: text)
            else { return nil }
            return DetectedLink(url: url, range: range)
        }
    }

    /// `text` inchangé, avec un attribut `.link` sur chaque lien autorisé
    /// (SwiftUI le colore avec la teinte de la vue).
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for link in links(in: text) {
            guard let range = Range<AttributedString.Index>(link.range, in: result) else { continue }
            result[range].link = link.url
        }
        return result
    }
}
