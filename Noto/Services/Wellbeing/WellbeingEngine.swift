import Foundation

/// Heuristic "something seems off" detector that runs over the signals
/// already in SwiftData (grades, homework, messages). Never a diagnostic
/// tool — the goal is to surface patterns a parent might miss when
/// glancing at individual screens, framed as observations, not verdicts.
///
/// Design constraints (see also `project_phase_8_directory.md` and the
/// Charles cross-repo notes):
///   - No network, no scoring model, no questionnaire. Pure local rules.
///   - Single-factor triggers are suppressed — too many false positives.
///     A signal requires at least `factorThreshold` independent factors
///     that each pass their own conservative threshold.
///   - Copy is parent-addressed French and framed as "signaux à observer",
///     never "votre enfant va mal".
enum WellbeingEngine {

    /// Minimum number of independent factors that must fire before
    /// we surface anything. Two was calibrated against the sample
    /// Sophie C. persona: grade dips + homework lapses are common
    /// individually but rarely co-occur without reason.
    static let factorThreshold = 2

    /// Window over which we sample the signals. Aligned with the
    /// school week cadence — longer and we chase stale patterns,
    /// shorter and weekly variance dominates.
    static let observationWindowDays = 28

    // MARK: - Public API

    /// Evaluates one child. Returns nil when nothing crosses the
    /// threshold — callers must not render any card in that case.
    static func detect(for child: Child, now: Date = .now) -> WellbeingSignal? {
        var factors: [WellbeingFactor] = []
        let windowStart = Calendar.current.date(byAdding: .day, value: -observationWindowDays, to: now) ?? now

        if let f = detectGradeDecline(child: child, windowStart: windowStart) { factors.append(f) }
        if let f = detectUnreadBacklog(child: child, now: now) { factors.append(f) }
        if let f = detectHomeworkBacklog(child: child, windowStart: windowStart, now: now) { factors.append(f) }

        guard factors.count >= factorThreshold else { return nil }
        return WellbeingSignal(childName: child.firstName, factors: factors, observedAt: now)
    }

    /// Evaluates every child. Returns the non-nil signals in the order
    /// the children are passed — callers decide ordering within the feed.
    static func detect(for children: [Child], now: Date = .now) -> [WellbeingSignal] {
        children.compactMap { detect(for: $0, now: now) }
    }

    // MARK: - Factor detectors (internal so tests can exercise each directly)

    /// Fires when the child's overall average over the window sits
    /// below 10/20 AND the child has `.difficulty`-type insights from
    /// the existing InsightEngine in at least two subjects. Two conditions
    /// keep single-bad-grade noise from triggering.
    static func detectGradeDecline(child: Child, windowStart: Date) -> WellbeingFactor? {
        let recent = child.grades.filter { $0.date >= windowStart }
        guard recent.count >= 3 else { return nil }

        let sum = recent.map(\.normalizedValue).reduce(0, +)
        let avg = sum / Double(recent.count)
        guard avg < 10 else { return nil }

        let difficultySubjects = Set(
            child.insights
                .filter { $0.type == .difficulty }
                .map(\.subject)
        )
        guard difficultySubjects.count >= 2 else { return nil }

        let subjectsLabel = difficultySubjects.sorted().prefix(2).joined(separator: " et ")
        return WellbeingFactor(
            kind: .sustainedGradeDecline,
            detail: "Baisse en \(subjectsLabel) (moy. \(format(avg)))"
        )
    }

    /// Fires when at least three unread messages accumulate — regardless
    /// of sender. A single urgent unread is already surfaced by the
    /// existing message card; this is specifically about backlog,
    /// which often reads as disengagement.
    static func detectUnreadBacklog(child: Child, now: Date, minimum: Int = 3) -> WellbeingFactor? {
        let unread = child.messages.filter { !$0.read }
        guard unread.count >= minimum else { return nil }
        return WellbeingFactor(
            kind: .unreadBacklog,
            detail: "\(unread.count) messages non lus"
        )
    }

    /// Fires when, across the window, more than half of the past-due
    /// homework items never got marked done. Only past-due items count
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

        return WellbeingFactor(
            kind: .homeworkBacklog,
            detail: "\(undone.count) devoirs sur \(pastDue.count) non faits"
        )
    }

    // MARK: - Helpers

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Models

struct WellbeingFactor: Equatable, Sendable {
    enum Kind: String, Sendable, Equatable {
        case sustainedGradeDecline
        case unreadBacklog
        case homeworkBacklog
    }

    let kind: Kind
    let detail: String
}

/// Surface-level payload the briefing UI renders. Computed on-the-fly —
/// not persisted. Regenerated every briefing rebuild so wellbeing state
/// always reflects the current signals.
struct WellbeingSignal: Equatable, Sendable {
    let childName: String
    let factors: [WellbeingFactor]
    let observedAt: Date

    var severity: BriefingPriority {
        factors.count >= 3 ? .urgent : .normal
    }

    var title: String {
        "Signes à observer — \(childName)"
    }

    var subtitle: String {
        factors.map(\.detail).joined(separator: " · ")
    }
}
