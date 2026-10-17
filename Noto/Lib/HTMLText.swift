import Foundation

/// HTML → plain text for school content (ENT feed, webmail bodies). Block and
/// break tags become newlines before the remaining tags are dropped, so
/// adjacent blocks never merge — `<p>https://a.fr/x</p><p>/y</p>` must not
/// turn into one bogus link once the text is linkified.
enum HTMLText {
    static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</(p|div|li|tr|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"),
                               ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
            .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
