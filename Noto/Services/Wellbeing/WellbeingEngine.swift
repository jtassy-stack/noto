import Foundation

/// Heuristic "something seems off" detector that runs over the signals
/// already in SwiftData (grades, homework, messages). Never a diagnostic
/// tool — the goal is to surface patterns a parent might miss when
/// glancing at individual screens, framed as observations, not verdicts.
///
/// Design constraints:
///   - No network, no scoring model, no questionnaire. Pure local rules.
///   - Single-factor triggers are suppressed — too many false positives.
///     A signal requires at least `factorThreshold` independent factors
///     that each pass their own conservative threshold.
///   - Copy is parent-addressed French and framed as "signaux à observer",
///     never "votre enfant va mal".
enum WellbeingEngine {

    /// Minimum number of independent factors that must fire before
    /// we surface anything. Two was calibrated against the Sophie C.
    /// persona: grade dips and homework lapses are common individually
    /// but rarely co-occur without reason.
    static let factorThreshold = 2

    /// Window over which we sample the signals. Aligned with the
    /// school week cadence — longer and we chase stale patterns,
    /// shorter and weekly variance dominates.
    static let observationWindowDays = 28

    // MARK: - Public API

    /// Evaluates one child. Returns nil when nothing crosses the
    /// threshold — callers must not render any card in that case.
    static func detect(for child: Child, now: Date = .now) -> WellbeingSignal? {
        guard let windowStart = Calendar.current.date(byAdding: .day, value: -observationWindowDays, to: now) else {
            assertionFailure("WellbeingEngine: Calendar failed to compute windowStart from \(now)")
            return nil
        }

        var factors: [WellbeingFactor] = []
        if let f = detectGradeDecline(child: child, windowStart: windowStart) { factors.append(f) }
        if let f = detectUnreadBacklog(child: child, windowStart: windowStart, now: now) { factors.append(f) }
        if let f = detectHomeworkBacklog(child: child, windowStart: windowStart, now: now) { factors.append(f) }

        return WellbeingSignal.make(childName: child.firstName, childLevel: child.level, factors: factors)
    }

    /// Evaluates every child. Returns the non-nil signals in the order
    /// the children are passed — callers decide ordering within the feed.
    static func detect(for children: [Child], now: Date = .now) -> [WellbeingSignal] {
        children.compactMap { detect(for: $0, now: now) }
    }

    // MARK: - Factor detectors (internal so tests can exercise each directly)

    /// Fires when the child's coefficient-weighted average over the window
    /// sits below 10/20 AND the InsightEngine flagged difficulty in at least
    /// two subjects. Both conditions prevent single-bad-grade noise.
    static func detectGradeDecline(child: Child, windowStart: Date) -> WellbeingFactor? {
        let recent = child.grades.filter { $0.date >= windowStart }
        guard recent.count >= 3 else { return nil }

        let totalCoeff = recent.reduce(0.0) { $0 + $1.coefficient }
        guard totalCoeff > 0 else { return nil }
        let avg = recent.reduce(0.0) { $0 + $1.normalizedValue * $1.coefficient } / totalCoeff
        guard avg < 10 else { return nil }

        let difficultySubjects = Set(
            child.insights
                .filter { $0.type == .difficulty }
                .map(\.subject)
        )
        guard difficultySubjects.count >= 2 else { return nil }

        return WellbeingFactor(kind: .sustainedGradeDecline(subjects: Array(difficultySubjects), average: avg))
    }

    /// Fires when at least `minimum` unread messages accumulated within the
    /// observation window — stale unreads outside the window are excluded so
    /// old ignored messages don't silently tip the threshold.
    static func detectUnreadBacklog(child: Child, windowStart: Date, now: Date, minimum: Int = 3) -> WellbeingFactor? {
        let unread = child.messages.filter { !$0.read && $0.date >= windowStart && $0.date < now }
        guard unread.count >= minimum else { return nil }
        return WellbeingFactor(kind: .unreadBacklog(count: unread.count))
    }

    /// Fires when, across the window, more than half of the past-due
    /// homework items were never marked done. Only past-due items count
    /// — future homework isn't a wellbeing signal, it's just a to-do.
    static func detectHomeworkBacklog(
        child: Child,
        windowStart: Date,
        now: Date,
        threshold: Double = 0.5
    ) -> WellbeingFactor? {
        let pastDue = child.homework.filter { $0.dueDate >= windowStart && $0.dueDate < now }
        guard pastDue.count >= 4 else { return nil }

        let undone = pastDue.filter { !$0.done }
        let ratio = Double(undone.count) / Double(pastDue.count)
        guard ratio > threshold else { return nil }

        return WellbeingFactor(kind: .homeworkBacklog(undone: undone.count, total: pastDue.count))
    }
}

// MARK: - Models

struct WellbeingFactor: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sustainedGradeDecline(subjects: [String], average: Double)
        case unreadBacklog(count: Int)
        case homeworkBacklog(undone: Int, total: Int)

        var detail: String {
            switch self {
            case let .sustainedGradeDecline(subjects, avg):
                let label = subjects.sorted().prefix(2).joined(separator: " et ")
                return "Baisse en \(label) (moy. \(String(format: "%.1f", avg)))"
            case let .unreadBacklog(count):
                return "\(count) messages non lus"
            case let .homeworkBacklog(undone, total):
                return "\(undone) devoirs sur \(total) non faits"
            }
        }
    }

    let kind: Kind
    var detail: String { kind.detail }
}

/// Surface-level payload the briefing UI renders. Computed on-the-fly —
/// not persisted. `make()` guarantees at least 2 factors; construction
/// outside the engine is not possible.
struct WellbeingSignal: Equatable, Sendable {
    enum Severity: Equatable, Sendable { case notable, urgent }

    let childName: String
    let childLevel: SchoolLevel
    let factors: [WellbeingFactor]  // count >= 2, guaranteed by make()

    var severity: Severity { factors.count >= 3 ? .urgent : .notable }
    var title: String { "Signes à observer — \(childName)" }
    var subtitle: String { factors.map(\.detail).joined(separator: " · ") }

    /// Returns nil when fewer than 2 factors are present — callers receive
    /// the enforcement rather than accidentally building a one-factor signal.
    static func make(childName: String, childLevel: SchoolLevel, factors: [WellbeingFactor]) -> WellbeingSignal? {
        guard factors.count >= 2 else { return nil }
        return WellbeingSignal(childName: childName, childLevel: childLevel, factors: factors)
    }

    private init(childName: String, childLevel: SchoolLevel, factors: [WellbeingFactor]) {
        self.childName = childName
        self.childLevel = childLevel
        self.factors = factors
    }
}
