import Foundation

/// Parent Messages tab: which messages wait on the parent (« À traiter ») and
/// the week's volume per source. Pure: values in, values out, `now` and
/// `calendar` passed in. Keyword rules on the subject and the plain-text
/// body, folded (case and diacritics), never sent anywhere.
enum MessageTriage {
    enum Action: String, Sendable, CaseIterable {
        case sign, justify, reply

        /// Button label, parent-facing.
        var label: String {
            switch self {
            case .sign: "Signer"
            case .justify: "Justifier"
            case .reply: "Répondre"
            }
        }
    }

    /// Source groups shown in the week's volume line.
    enum Channel: String, Sendable, CaseIterable {
        case pronote, mail, ent

        var label: String {
            switch self {
            case .pronote: "Pronote"
            case .mail: "Mails"
            case .ent: "ENT"
            }
        }

        init(_ source: MessageSource) {
            switch source {
            case .pronote: self = .pronote
            case .imap, .monlycee: self = .mail
            case .ent: self = .ent
            }
        }
    }

    /// An unread message older than this no longer counts as waiting.
    static let pendingWindowDays = 30

    static let justifyKeywords = ["justifi"]
    static let signKeywords = ["a signer", "signature", "autorisation", "coupon", "talon"]
    static let replyKeywords = ["repondre", "reponse attendue", "merci de confirmer", "creneau", "creneaux"]

    /// What the parent is asked to do, or nil. Read messages are handled: the
    /// model has no « done » state, opening a message clears it.
    static func action(subject: String, plainBody: String, kind: MessageKind, read: Bool,
                       date: Date, now: Date, calendar: Calendar) -> Action? {
        guard !read else { return nil }
        if let start = calendar.date(byAdding: .day, value: -pendingWindowDays, to: calendar.startOfDay(for: now)),
           date < start {
            return nil
        }
        if kind == .schoolbook { return .sign }
        let text = fold(subject + " " + plainBody)
        if justifyKeywords.contains(where: { text.contains($0) }) { return .justify }
        if signKeywords.contains(where: { text.contains($0) }) { return .sign }
        if replyKeywords.contains(where: { text.contains($0) }) { return .reply }
        return nil
    }

    struct ChannelCount: Equatable, Sendable {
        let channel: Channel
        let count: Int
    }

    struct WeekVolume: Equatable, Sendable {
        let total: Int
        /// Channels with at least one message, in `Channel.allCases` order.
        let perChannel: [ChannelCount]
    }

    /// Messages of the last 7 days (today included).
    static func weekVolume(_ items: [(source: MessageSource, date: Date)], now: Date,
                           calendar: Calendar) -> WeekVolume {
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let week = items.filter { $0.date >= start && $0.date <= now }
        let counts = Dictionary(grouping: week, by: { Channel($0.source) }).mapValues(\.count)
        return WeekVolume(total: week.count,
                          perChannel: Channel.allCases.compactMap { c in counts[c].map { ChannelCount(channel: c, count: $0) } })
    }

    /// « 25 messages · 3 à traiter », parent-facing.
    static func summaryLine(total: Int, pending: Int) -> String {
        let messages = total == 1 ? "1 message" : "\(total) messages"
        return pending > 0 ? "\(messages) · \(pending) à traiter" : messages
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
}
