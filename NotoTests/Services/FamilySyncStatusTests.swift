import Testing
import Foundation
@testable import Noto

/// Family sync (phase 9.4): what the parent and child screens say about the
/// sync, in the parent's tone (vouvoiement).
@Suite("FamilySyncStatus")
struct FamilySyncStatusTests {
    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        paris.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func syncedTextReadsLikeAClock() {
        let now = date(day: 19, hour: 18)
        #expect(FamilySyncLink.syncedText(nil, now: now, calendar: paris) == "Pas encore synchronisé")
        #expect(FamilySyncLink.syncedText(now.addingTimeInterval(-20), now: now, calendar: paris)
            == "Synchronisé à l'instant")
        // A clock slightly ahead on the other side is still « à l'instant ».
        #expect(FamilySyncLink.syncedText(now.addingTimeInterval(30), now: now, calendar: paris)
            == "Synchronisé à l'instant")
        #expect(FamilySyncLink.syncedText(now.addingTimeInterval(-5 * 60), now: now, calendar: paris)
            == "Synchronisé il y a 5 min")
        #expect(FamilySyncLink.syncedText(date(day: 19, hour: 14, minute: 5), now: now, calendar: paris)
            == "Synchronisé aujourd'hui à 14h05")
        #expect(FamilySyncLink.syncedText(date(day: 18, hour: 21, minute: 30), now: now, calendar: paris)
            == "Synchronisé hier à 21h30")
        #expect(FamilySyncLink.syncedText(date(day: 12, hour: 9), now: now, calendar: paris)
            == "Synchronisé le 12 octobre")
    }

    @Test func reserveOnlyForTodayAndWhenThereIsSome() {
        let now = date(day: 19, hour: 11)
        let today = RewardLedger.dayKey(for: now, calendar: paris)
        #expect(FamilySyncLink.reserveText(SyncedDayMinutes(day: today, credited: 10, pending: 0, reserve: 6),
                                           now: now, calendar: paris)
            == "6 min gagnées pendant les cours, gardées pour après les cours.")
        #expect(FamilySyncLink.reserveText(SyncedDayMinutes(day: today, credited: 10, pending: 10, reserve: 0),
                                           now: now, calendar: paris) == nil)
        #expect(FamilySyncLink.reserveText(SyncedDayMinutes(day: "2026-10-18", credited: 10, pending: 0,
                                                            reserve: 6),
                                           now: now, calendar: paris) == nil)
        #expect(FamilySyncLink.reserveText(nil, now: now, calendar: paris) == nil)
    }

    @MainActor
    @Test func linkedScreensWaitForTheChildsPhone() {
        for text in [ParentWeekSection.noRevisionText("Gaston", linked: true),
                     FamilySyncLink.waitingMinutesText(firstName: "Gaston"),
                     ChildPreviewBanner.detail("Gaston", linked: true)] {
            #expect(text.contains("Gaston"))
            // No « sur l'appareil où … fait ses quiz » once the phones are linked.
            #expect(!text.contains("fait ses quiz"))
            #expect(!text.contains(" tu ") && !text.contains(" ton ") && !text.contains(" tes "))
        }
        #expect(ParentWeekSection.noRevisionText("Gaston", linked: true)
            == "Les révisions de Gaston s'afficheront ici après la prochaine synchronisation de son téléphone.")
    }

    @Test func comparisonWaitsForTheSyncWhenLinked() {
        let empty = ParentQuizComparison(notionCount: 3, mastered: 0, inProgress: 0, fragile: 0)
        #expect(empty.sentence(firstName: "Léa", linked: true)
            == "Les révisions de Léa ne sont pas encore arrivées sur ce téléphone : "
            + "la comparaison s'affichera après la prochaine synchronisation.")
        #expect(empty.sentence(firstName: "Léa")?.contains("fait ses quiz") == true)
    }
}
