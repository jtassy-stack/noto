import Foundation

/// Pure builder for the parent-facing warning strings shown in the
/// `GlobalStatusBanner` on Home. Takes an injected `now` so tests
/// can pin boundary behavior without date flakiness.
///
/// Extracted from `HomeView.GlobalStatusBanner` so the pluralisation
/// and ordering rules are unit-testable.
enum AlertMessageBuilder {

    /// Returns the list of alert lines for `children`, in a stable order:
    /// urgent homework first (in child order), then low-grade counts.
    /// An empty array means "Tout va bien".
    static func messages(for children: [Child], now: Date = .now) -> [String] {
        var msgs: [String] = []
        let in24h = now.addingTimeInterval(86_400)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)

        for child in children {
            let urgent = child.homework.filter { !$0.done && $0.dueDate <= in24h }
            guard !urgent.isEmpty else { continue }
            if urgent.count == 1, let hw = urgent.first {
                msgs.append("\(child.firstName) a 1 devoir de \(hw.subject.localizedCapitalized) pour demain")
            } else {
                let subjects = urgent.prefix(3).map(\.subject.localizedCapitalized).joined(separator: ", ")
                msgs.append("\(child.firstName) a \(urgent.count) devoirs pour demain (\(subjects))")
            }
        }

        for child in children {
            let lows = child.grades.filter { $0.date >= sevenDaysAgo && $0.normalizedValue < 10 }
            guard !lows.isEmpty else { continue }
            msgs.append("\(child.firstName) a \(lows.count) note\(lows.count > 1 ? "s" : "") sous 10 cette semaine")
        }

        return msgs
    }
}
