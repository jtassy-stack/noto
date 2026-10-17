import Testing
import Foundation
@testable import Noto

/// Parent Messages tab: « À traiter » and the week's volume (`MessageTriage`).
@Suite("MessageTriage")
struct MessageTriageTests {
    private let paris = QuizClock.calendar
    private let now = QuizClock.date(day: 0, hour: 18)

    private func action(_ subject: String, body: String = "", kind: MessageKind = .conversation,
                        read: Bool = false, day: Int = -1) -> MessageTriage.Action? {
        MessageTriage.action(subject: subject, plainBody: body, kind: kind, read: read,
                             date: QuizClock.date(day: day, hour: 9), now: now, calendar: paris)
    }

    @Test func detectsWhatTheParentHasToDo() {
        #expect(action("Sortie au musée : autorisation à signer") == .sign)
        #expect(action("Absence de lundi à justifier") == .justify)
        #expect(action("Professeur principal : rendez-vous parents",
                       body: "Réponse attendue, 3 créneaux proposés.") == .reply)
        #expect(action("Menus de la cantine, semaine 43") == nil)
    }

    @Test func unreadCarnetIsToSign() {
        #expect(action("Information", kind: .schoolbook) == .sign)
    }

    @Test func readOrOldMessagesAreNotPending() {
        #expect(action("Absence à justifier", read: true) == nil)
        #expect(action("Absence à justifier", day: -(MessageTriage.pendingWindowDays + 1)) == nil)
    }

    @Test func weekVolumeGroupsMailSources() {
        let items: [(source: MessageSource, date: Date)] = [
            (.pronote, QuizClock.date(day: 0, hour: 8)),
            (.pronote, QuizClock.date(day: -6, hour: 8)),
            (.imap, QuizClock.date(day: -2, hour: 8)),
            (.monlycee, QuizClock.date(day: -3, hour: 8)),
            (.ent, QuizClock.date(day: -7, hour: 8)),
        ]
        let volume = MessageTriage.weekVolume(items, now: now, calendar: paris)
        #expect(volume.total == 4)
        #expect(volume.perChannel == [MessageTriage.ChannelCount(channel: .pronote, count: 2),
                                      MessageTriage.ChannelCount(channel: .mail, count: 2)])
    }

    @Test func summaryLine() {
        #expect(MessageTriage.summaryLine(total: 25, pending: 3) == "25 messages · 3 à traiter")
        #expect(MessageTriage.summaryLine(total: 1, pending: 0) == "1 message")
    }
}
