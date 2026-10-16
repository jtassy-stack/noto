import Foundation

/// Bank strings (celyn questions, choices, explanations) may carry inline
/// Markdown such as `*Les Métamorphoses*`. A runtime `String` passed to
/// `Text` is rendered verbatim, so the child would see the asterisks.
/// `attributed` interprets inline Markdown only (no block syntax, whitespace
/// kept); `plain` drops the markup for VoiceOver labels and string
/// interpolation. Unparseable input falls back to the raw string.
enum BankText {
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func attributed(_ raw: String) -> AttributedString {
        (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    static func plain(_ raw: String) -> String {
        String(attributed(raw).characters)
    }
}
