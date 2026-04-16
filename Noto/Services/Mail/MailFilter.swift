import Foundation

/// Pure filter — decides whether an IMAP-fetched message should be
/// persisted to SwiftData based on the whitelist.
///
/// The filter is strict-by-default: if the whitelist is empty (no
/// school domain detected, no manual entries), the caller should
/// disable filtering rather than drop everything. The filter itself
/// reports "should keep" for a given message + whitelist pair.
enum MailFilter {

    /// Returns true if the email matches any whitelist entry.
    static func shouldKeep(
        senderAddress: String,
        subject: String,
        whitelist: [MailWhitelistEntry]
    ) -> Bool {
        guard let email = MailWhitelist.extractEmail(from: senderAddress) else {
            // Sender not parseable — be conservative and drop it rather
            // than let it through on subject alone.
            return false
        }

        let senderDomain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""

        for entry in whitelist {
            if entry.isDomainPattern {
                // Domain match — sender's domain equals or endsWith the pattern.
                // `endsWith` covers subdomain entries like `index-education.net`
                // matching `xxxxx.index-education.net`.
                if senderDomain == entry.pattern || senderDomain.hasSuffix("." + entry.pattern) {
                    return true
                }
            } else {
                // Exact email match.
                if email == entry.pattern {
                    return true
                }
            }
        }
        return false
    }
}
