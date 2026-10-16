import Testing
import Foundation
import SwiftData
import UserNotifications
@testable import Noto

/// Parent-side revision reports (3.7): `RevisionSummary`, the weekly
/// `RevisionSuggestion` rules, the « Révisions » briefing item, the weekly
/// notification request, and the guided Screen Time profiles. Pure, on
/// `QuizClock` (2023-11-14 23:13 Paris, a Tuesday).
@Suite("RevisionReport")
struct RevisionReportTests {
    private let now = QuizClock.now
    private let calendar = QuizClock.calendar

    private func attempt(day: Int, hour: Int = 18, total: Int = 5, minutes: Int = 10, passed: Bool = true,
                         denial: RewardDenial? = nil) -> AttemptSnapshot {
        AttemptSnapshot(date: QuizClock.date(day: day, hour: hour), questionKeys: ["k\(day)\(hour)"],
                        correctCount: total, totalCount: total, durationSec: 60, minutesEarned: minutes,
                        passed: passed, denial: denial)
    }

    private func mastery(_ key: String, box: Int, reviewedDay: Int? = nil) -> MasterySnapshot {
        MasterySnapshot(notionKey: key, leitnerBox: box, nextReview: QuizClock.date(day: 1), streakCorrect: 0,
                        lastReviewedAt: reviewedDay.map { QuizClock.date(day: $0, hour: 18) })
    }

    private func summary(_ attempts: [AttemptSnapshot], masteries: [MasterySnapshot] = [],
                         streak: Int = 0, at date: Date? = nil) -> RevisionSummary {
        RevisionSummary.build(attempts: attempts, masteries: masteries, streakDays: streak,
                              now: date ?? now, calendar: calendar)
    }

    // MARK: Summary

    @Test("7 / 30-day windows, minutes, mastery buckets, today's notions")
    func build() {
        let attempts = [
            attempt(day: 0, minutes: 10), attempt(day: 0, hour: 20, minutes: 5),
            attempt(day: -3, minutes: 0, passed: false, denial: .belowThreshold),
            attempt(day: -6, minutes: 5),                 // still inside 7 days (today counts)
            attempt(day: -7, minutes: 10),                // 8th day back: 30-day only
            attempt(day: -29, minutes: 10),
            attempt(day: -30, minutes: 10),               // outside 30 days
            attempt(day: 0, total: 0, minutes: 0, passed: false, denial: .emptyQuiz), // ignored
        ]
        let masteries = [mastery("a", box: 5, reviewedDay: -2), mastery("b", box: 4, reviewedDay: 0),
                         mastery("c", box: 3), mastery("d", box: 2, reviewedDay: 0), mastery("e", box: 1, reviewedDay: -1)]
        let s = summary(attempts, masteries: masteries, streak: 4)
        #expect(s.quizzes7d == 4)
        #expect(s.quizzes30d == 6)
        #expect(s.passed7d == 3)
        #expect(s.minutesEarnedToday == 15)
        #expect(s.minutesEarned7d == 20)
        #expect(s.minutesUsed7d == nil)
        #expect(s.masteredCount == 2)
        #expect(s.inProgressCount == 1)
        #expect(s.fragileCount == 2)
        #expect(s.fragileNotionKeys == ["e", "d"])
        #expect(s.notionsReviewedToday == 2)
        #expect(s.quizzesToday == 2)
        #expect(s.streakDays == 4)
        #expect(s.lastQuizDate == QuizClock.date(day: 0, hour: 20))
        #expect(s.belowThreshold7d == 1)
        #expect(s.isActive)
    }

    @Test("nothing played: inactive, empty sentence")
    func empty() {
        let s = summary([])
        #expect(!s.isActive)
        #expect(s.lastQuizDate == nil)
        #expect(s.weeklySentence == "Pas de révision ces 7 derniers jours.")
    }

    @Test("weekly sentence addresses the parent")
    func weeklySentence() {
        let s = summary([attempt(day: 0), attempt(day: -1, minutes: 5),
                         attempt(day: -2, minutes: 0, passed: false, denial: .belowThreshold)])
        #expect(s.weeklySentence == "Ces 7 derniers jours, votre enfant a fait 3 quiz (2 réussis) et gagné 15 min.")
    }

    // MARK: Weekly suggestion

    @Test("many quizzes below the threshold → suggest 3/5")
    func suggestLowerThreshold() {
        let failed = (0..<3).map { attempt(day: -$0, minutes: 0, passed: false, denial: .belowThreshold) }
        let s = summary(failed + [attempt(day: -4)])
        #expect(RevisionSuggestion.suggest(summary: s, config: .default) == .lowerThreshold)
        // Already at 3/5: nothing to lower.
        var lenient = RewardConfig.default
        lenient.passThreshold = 0.6
        #expect(RevisionSuggestion.suggest(summary: s, config: lenient) == nil)
        #expect(RevisionSuggestion.lowerThreshold.applied(to: .default).passThreshold == 0.6)
    }

    @Test("failures that are a minority of the week do not trigger it")
    func belowThresholdMinority() {
        let failed = (0..<3).map { attempt(day: -$0, hour: 8, minutes: 0, passed: false, denial: .belowThreshold) }
        let passed = (0..<4).map { attempt(day: -$0, minutes: 5) }
        #expect(RevisionSuggestion.suggest(summary: summary(failed + passed), config: .default) == nil)
    }

    @Test("cap reached on 3 distinct days → suggest +10 min")
    func suggestRaiseCap() {
        // Barème above the cap: the cap, not the tiers, is what stops the child.
        var config = RewardConfig.default
        config.tiers = [10, 10, 10]
        let capped = [attempt(day: 0, minutes: 0, denial: .capReached),
                      attempt(day: -1, minutes: 0, denial: .capReached),
                      attempt(day: -2, minutes: 0, denial: .capReached)]
        let suggestion = RevisionSuggestion.suggest(summary: summary(capped), config: config)
        #expect(suggestion == .raiseCap(to: 30))
        #expect(suggestion?.text.contains("30 min") == true)
        #expect(suggestion?.applied(to: config).dailyCap == 30)

        // Same day three times is not « souvent ».
        let sameDay = (0..<3).map { attempt(day: 0, hour: 17 + $0, minutes: 0, denial: .capReached) }
        #expect(RevisionSuggestion.suggest(summary: summary(sameDay), config: config) == nil)

        // Already at the maximum.
        var maxed = config
        maxed.dailyCap = RewardConfig.dailyCapRange.upperBound
        #expect(RevisionSuggestion.suggest(summary: summary(capped), config: maxed) == nil)
    }

    @Test("tiers exhausted is not « plafond atteint »: a higher cap would not earn more")
    func tiersExhaustedDoesNotRaiseCap() {
        // Default barème 10/5/5 sums to the default cap of 20: a 4th quiz is
        // always `.tiersExhausted`, never `.capReached`.
        let exhausted = (0..<3).map { attempt(day: -$0, minutes: 0, denial: .tiersExhausted) }
        let s = summary(exhausted)
        #expect(s.capDays7d == 0)
        #expect(s.capOrTiersReached7d == 3)
        #expect(RevisionSuggestion.suggest(summary: s, config: .default) == nil)

        // `.capReached` days with a barème that cannot exceed the cap: no
        // suggestion either (raising the cap changes nothing).
        let capped = (0..<3).map { attempt(day: -$0, minutes: 0, denial: .capReached) }
        #expect(RevisionSuggestion.suggest(summary: summary(capped), config: .default) == nil)
    }

    @Test("quizzes too short → suggest a lower minimum length")
    func suggestLowerMinimum() {
        let short = [attempt(day: 0, total: 3, minutes: 0, passed: false, denial: .tooShort),
                     attempt(day: -1, total: 3, minutes: 0, passed: false, denial: .tooShort)]
        #expect(RevisionSuggestion.suggest(summary: summary(short), config: .default) == .lowerMinimumLength(to: 4))
    }

    @Test("the threshold rule wins over the cap rule")
    func suggestionOrder() {
        let failed = (0..<3).map { attempt(day: -$0, hour: 8, minutes: 0, passed: false, denial: .belowThreshold) }
        let capped = (0..<3).map { attempt(day: -$0, minutes: 0, denial: .capReached) }
        #expect(RevisionSuggestion.suggest(summary: summary(failed + capped), config: .default) == .lowerThreshold)
    }

    @Test("suggestion copy uses vouvoiement")
    func suggestionTone() {
        for suggestion in [RevisionSuggestion.lowerThreshold, .raiseCap(to: 30), .lowerMinimumLength(to: 4)] {
            #expect(suggestion.text.contains("vous") || suggestion.text.contains("Votre"))
            #expect(!suggestion.text.lowercased().contains(" tu "))
        }
    }

    // MARK: Briefing item

    @Test("revised today: notions count, low priority")
    func briefingRevisedToday() throws {
        let s = summary([attempt(day: 0)], masteries: [mastery("a", box: 2, reviewedDay: 0),
                                                       mastery("b", box: 2, reviewedDay: 0)], streak: 3)
        let item = try #require(RevisionBriefingItem.make(summary: s, examTomorrow: true, now: now, calendar: calendar))
        #expect(item.title == "Votre enfant a révisé 2 notions aujourd'hui")
        #expect(item.subtitle == "10 min gagnées · série de 3 jours")
        #expect(item.priority == .low)
    }

    @Test("a quiz today without a notion update: counts quizzes")
    func briefingQuizOnly() throws {
        let item = try #require(RevisionBriefingItem.make(summary: summary([attempt(day: 0)]), examTomorrow: false,
                                                          now: now, calendar: calendar))
        #expect(item.title == "Votre enfant a fait 1 quiz de révision aujourd'hui")
    }

    @Test("nothing today, contrôle tomorrow → medium (.normal)")
    func briefingExamTomorrow() throws {
        let morning = QuizClock.date(day: 0, hour: 8)
        let item = try #require(RevisionBriefingItem.make(summary: summary([attempt(day: -1)], at: morning),
                                                          examTomorrow: true, now: morning, calendar: calendar))
        #expect(item.title == "Pas encore de révision aujourd'hui")
        #expect(item.priority == .normal)
        #expect(item.subtitle.contains("contrôle"))
    }

    @Test("nothing today, no contrôle: only in the evening, low")
    func briefingNothingToday() throws {
        let morning = QuizClock.date(day: 0, hour: 9)
        #expect(RevisionBriefingItem.make(summary: summary([attempt(day: -1)], at: morning), examTomorrow: false,
                                          now: morning, calendar: calendar) == nil)
        let item = try #require(RevisionBriefingItem.make(summary: summary([attempt(day: -1)], streak: 1),
                                                          examTomorrow: false, now: now, calendar: calendar))
        #expect(item.priority == .low)
        #expect(item.subtitle == "Série en cours : 1 jour")
    }

    @Test("never revised on this device (or not for 30 days): no item, even before a contrôle")
    func briefingInactive() {
        #expect(RevisionBriefingItem.make(summary: summary([]), examTomorrow: true, now: now, calendar: calendar) == nil)
        #expect(RevisionBriefingItem.make(summary: summary([attempt(day: -40)]), examTomorrow: true,
                                          now: now, calendar: calendar) == nil)
    }

    // MARK: Notion labels

    @Test("notion key → curriculum subject and theme")
    func notionLabel() {
        let key = NotionKey.make(level: "4e", subject: "Mathématiques", theme: "Théorème de Pythagore")
        #expect(RevisionNotionLabel.label(for: key, programs: QuizCurriculumFixtures.programs)
                == "Mathématiques · Théorème de Pythagore")
        #expect(RevisionNotionLabel.label(for: "4e|maths|disparu", programs: QuizCurriculumFixtures.programs) == "Disparu")
    }

    // MARK: Weekly notification

    @Test("repeating Sunday 19:00 calendar trigger, fixed identifier")
    func weeklyRequest() throws {
        let request = WeeklyRevisionNotification.makeRequest(childNames: ["Léa"])
        #expect(request.identifier == "revisions.weekly")
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.weekday == 1)
        #expect(trigger.dateComponents.hour == 19)
        #expect(trigger.dateComponents.minute == 0)
        #expect(request.content.body.contains("de Léa"))
        #expect(request.content.title == "Bilan hebdo des révisions")
    }

    @Test("content names the children, parent tone, no figures")
    func weeklyContent() {
        #expect(WeeklyRevisionNotification.content(childNames: ["Léa", "Tom", "Inès"]).body
            .contains("de Léa, Tom et Inès"))
        #expect(WeeklyRevisionNotification.content(childNames: []).body.contains("de votre enfant"))
        #expect(!WeeklyRevisionNotification.content(childNames: ["Léa"]).body.contains(" tu "))
    }

    @Test("scheduled only when enabled, in parent mode, with revision data, and authorized")
    func weeklyGate() {
        let ok = { (enabled: Bool, mode: DeviceMode, names: [String], status: UNAuthorizationStatus) in
            WeeklyRevisionNotification.shouldSchedule(enabled: enabled, mode: mode, childNames: names, status: status)
        }
        #expect(ok(true, .parent, ["Léa"], .authorized))
        #expect(ok(true, .parent, ["Léa"], .provisional))
        #expect(!ok(false, .parent, ["Léa"], .authorized))
        #expect(!ok(true, .child, ["Léa"], .authorized))
        #expect(!ok(true, .parent, [], .authorized))
        #expect(!ok(true, .parent, ["Léa"], .denied))
        #expect(!ok(true, .parent, ["Léa"], .notDetermined))
    }

    // MARK: Guided Screen Time profiles

    @Test("profile suggested from the class")
    func profileFromGrade() {
        #expect(ScreenTimeAgeProfile.suggested(forGrade: "6ème") == .age11to13)
        #expect(ScreenTimeAgeProfile.suggested(forGrade: "3e") == .age14to15)
        #expect(ScreenTimeAgeProfile.suggested(forGrade: "2nde") == .age16to18)
        #expect(ScreenTimeAgeProfile.suggested(forGrade: "CM2") == nil)
    }

    @Test("a profile pre-fills the cap and barème, keeps the other rules")
    func profileApplied() {
        var custom = RewardConfig.default
        custom.passThreshold = 0.6
        custom.examEveBonusEnabled = false
        let applied = ScreenTimeAgeProfile.age14to15.applied(to: custom)
        #expect(applied.dailyCap == 30)
        #expect(applied.tiers == [10, 10, 10])
        #expect(applied.passThreshold == 0.6)
        #expect(!applied.examEveBonusEnabled)
        #expect(ScreenTimeAgeProfile.age11to13.applied(to: .default) == .default)
        #expect(ScreenTimeAgeProfile.age11to13.night.label == "21:00 – 07:00")
    }

    @Test("plan store round-trip, corrupt → nil")
    func planStore() {
        let suite = "ScreenTimePlanStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(ScreenTimePlanStore.load(defaults: defaults) == nil)
        var plan = ScreenTimePlan(profile: .age16to18)
        plan.night.startMinutes = 22 * 60 + 30
        ScreenTimePlanStore.save(plan, defaults: defaults)
        #expect(ScreenTimePlanStore.load(defaults: defaults) == plan)
        defaults.set(Data("x".utf8), forKey: ScreenTimePlanStore.key)
        #expect(ScreenTimePlanStore.load(defaults: defaults) == nil)
    }
}

/// `BriefingEngine.revisionCard` on an in-memory store: the « Révisions »
/// card is built from the child's attempts, masteries and homework.
@MainActor
@Suite("BriefingEngine+Révisions")
struct BriefingEngineRevisionTests {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(for: Schema(NotoSchemaV1.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func makeChild() -> Child {
        let child = Child(firstName: "Léa", level: .college, grade: "4ème", schoolType: .pronote,
                          establishment: "Collège Test")
        context.insert(child)
        return child
    }

    private func addAttempt(_ child: Child, day: Int, hour: Int = 18) {
        context.insert(QuizAttempt(child: child, date: QuizClock.date(day: day, hour: hour), itemIDs: [],
                                   questionKeys: ["q\(day)"], answers: [1, 1, 1, 1, 1], correctCount: 5,
                                   totalCount: 5, durationSec: 60, minutesEarned: 10, bonusApplied: false))
    }

    @Test("revised today → low-priority card with the notion count")
    func revisedToday() throws {
        let child = makeChild()
        addAttempt(child, day: 0)
        let mastery = NotionMastery(child: child, notionKey: "4e|histoire|revolution", now: QuizClock.now,
                                    calendar: QuizClock.calendar)
        mastery.lastReviewedAt = QuizClock.date(day: 0, hour: 18)
        context.insert(mastery)
        try context.save()

        let card = try #require(BriefingEngine.revisionCard(for: child, now: QuizClock.now, calendar: QuizClock.calendar))
        #expect(card.type == .revisions)
        #expect(card.childName == "Léa")
        #expect(card.title == "Votre enfant a révisé 1 notion aujourd'hui")
        #expect(card.priority == .low)
    }

    @Test("contrôle tomorrow and nothing revised today → .normal")
    func examTomorrow() throws {
        let child = makeChild()
        addAttempt(child, day: -1)
        let homework = Homework(subject: "MATHEMATIQUES", description: "Contrôle sur Pythagore",
                                dueDate: QuizClock.date(day: 1))
        context.insert(homework)
        homework.child = child
        try context.save()

        let card = try #require(BriefingEngine.revisionCard(for: child, now: QuizClock.now, calendar: QuizClock.calendar))
        #expect(card.title == "Pas encore de révision aujourd'hui")
        #expect(card.priority == .normal)
    }

    @Test("no quiz on this device → no card")
    func noData() throws {
        let child = makeChild()
        try context.save()
        #expect(BriefingEngine.revisionCard(for: child, now: QuizClock.now, calendar: QuizClock.calendar) == nil)
    }
}
