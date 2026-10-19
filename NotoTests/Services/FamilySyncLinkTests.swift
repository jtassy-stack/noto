import CloudKit
import Testing
import Foundation
@testable import Noto

/// Family sync (phase 9.2): the flag, the zone name and the link state.
@Suite("FamilySyncLink")
struct FamilySyncLinkTests {
    @Test func flagIsOffUnlessSetToYes() {
        #expect(!FamilySyncLink.isEnabled(info: nil))
        #expect(!FamilySyncLink.isEnabled(info: [:]))
        #expect(!FamilySyncLink.isEnabled(info: [FamilySyncLink.infoPlistKey: "NO"]))
        // Unset xcconfig variable: the plist keeps an empty string.
        #expect(!FamilySyncLink.isEnabled(info: [FamilySyncLink.infoPlistKey: ""]))
        #expect(FamilySyncLink.isEnabled(info: [FamilySyncLink.infoPlistKey: "YES"]))
        #expect(FamilySyncLink.isEnabled(info: [FamilySyncLink.infoPlistKey: "yes"]))
    }

    @Test func zoneNamesAreRandomAndOpaque() {
        let a = FamilySyncLink.makeZoneName()
        let b = FamilySyncLink.makeZoneName()
        #expect(a != b)
        #expect(FamilySyncLink.isFamilyZone(a))
        #expect(!FamilySyncLink.isFamilyZone("enfant-lea"))
        #expect(!FamilySyncLink.isFamilyZone("autre-\(UUID().uuidString)"))
        #expect(!FamilySyncLink.isFamilyZone("_defaultZone"))
    }

    @Test func onlyOurZoneWideSharesAreAccepted() {
        let zone = FamilySyncLink.makeZoneName()
        #expect(FamilySyncLink.isAcceptable(containerIdentifier: FamilySyncLink.containerIdentifier,
                                            zoneName: zone, shareRecordName: CKRecordNameZoneWideShare))
        #expect(!FamilySyncLink.isAcceptable(containerIdentifier: "iCloud.autre.app",
                                             zoneName: zone, shareRecordName: CKRecordNameZoneWideShare))
        #expect(!FamilySyncLink.isAcceptable(containerIdentifier: FamilySyncLink.containerIdentifier,
                                             zoneName: "photos", shareRecordName: CKRecordNameZoneWideShare))
        #expect(!FamilySyncLink.isAcceptable(containerIdentifier: FamilySyncLink.containerIdentifier,
                                             zoneName: zone, shareRecordName: "un-enregistrement"))
    }

    @Test func state() {
        let zone = FamilySyncLink.makeZoneName()
        let date = QuizClock.date(day: 0, hour: 17)
        #expect(FamilySyncLink.state(zoneName: nil, linkedAt: nil) == .notLinked)
        #expect(FamilySyncLink.state(zoneName: "pas-une-zone", linkedAt: date) == .notLinked)
        #expect(FamilySyncLink.state(zoneName: zone, linkedAt: nil) == .invited)
        #expect(FamilySyncLink.state(zoneName: zone, linkedAt: date) == .linked(since: date))
    }

    @Test func parentCopyAddressesTheParent() {
        let calendar = QuizClock.calendar
        let date = QuizClock.date(day: 0, hour: 17)
        let texts = [
            FamilySyncLink.parentStatus(.notLinked, firstName: "Léa", calendar: calendar),
            FamilySyncLink.parentStatus(.invited, firstName: "Léa", calendar: calendar),
            FamilySyncLink.parentStatus(.linked(since: date), firstName: "Léa", calendar: calendar),
            FamilySyncLink.parentExplanation(firstName: "Léa"),
        ]
        for text in texts {
            #expect(text.contains("Léa"))
            #expect(!text.contains(" tu ") && !text.contains(" ton ") && !text.contains(" tes "))
        }
        #expect(texts[2].hasSuffix("depuis le \(FamilySyncLink.dayText(date, calendar: calendar))."))
    }
}

@Suite("FamilySyncLink pending deletions")
struct FamilySyncPendingDeletionTests {
    @Test func queueKeepsFamilyZonesOnceUntilRemoved() throws {
        let suite = "FamilySyncPendingDeletionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = FamilySyncLink.makeZoneName()
        let b = FamilySyncLink.makeZoneName()
        FamilySyncLink.addPendingDeletion(a, defaults)
        FamilySyncLink.addPendingDeletion(a, defaults)
        FamilySyncLink.addPendingDeletion("pas-une-zone", defaults)
        FamilySyncLink.addPendingDeletion(b, defaults)
        #expect(FamilySyncLink.pendingDeletions(defaults) == [a, b])

        FamilySyncLink.removePendingDeletion(a, defaults)
        #expect(FamilySyncLink.pendingDeletions(defaults) == [b])
    }
}
