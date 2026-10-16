import Testing
import Foundation
import SwiftData
@testable import Noto

// MARK: - Fixtures

/// Synthetic webmail payloads. Field names follow the shapes the webmail's
/// own XHR traffic uses (`response.mailHeader[].id.msgId`, `dateUTC`,
/// `response.mail.message`); values are made up — no real mailbox content.
enum MonLyceeMailFixtures {
    static let headerList = Data("""
    {"response": {"mailHeader": [
      {"id": {"msgId": 1042}, "from": "Mme Dupont <dupont@monlycee.net>",
       "subject": "Conseil de classe", "dateUTC": 1760000000000, "unread": true},
      {"id": {"msgId": "1041"}, "from": {"name": "", "email": "vie-scolaire@monlycee.net"},
       "subject": "  ", "dateUTC": "1759990000", "unread": false},
      {"id": {"msgId": 1040}, "from": "\\"M. Martin\\" <martin@monlycee.net>",
       "subject": "Sortie", "date": "03/10/2025 08:30"},
      {"id": {}, "from": "sans-id@monlycee.net", "subject": "ignoré"},
      {"from": "pas-d-id@monlycee.net", "subject": "ignoré aussi"}
    ]}}
    """.utf8)

    static let emptyInbox = Data(#"{"response": {}}"#.utf8)

    static let mail = Data(#"""
    {"response": {"mail": {"message": "<html><head><style>p{color:red}</style></head><body><p>Bonjour,</p><p>Rendez-vous le 12&nbsp;octobre &amp; merci.<br/>L&#039;équipe</p></body></html>"}}}
    """#.utf8)

    /// What an expired session typically gets: the CAS login page, as HTML.
    static let loginPage = Data("<!DOCTYPE html><html><body>Connexion</body></html>".utf8)
}

// MARK: - Parser

@Suite("MonLyceeMailParser")
struct MonLyceeMailParserTests {

    @Test func decodesHeaderListAndSkipsRowsWithoutId() throws {
        let headers = try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.headerList)
        #expect(headers.map(\.msgId) == [1042, 1041, 1040])
    }

    @Test func epochMillisecondsAndNumericStringDatesBothDecode() throws {
        let headers = try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.headerList)
        #expect(headers[0].date == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(headers[1].date == Date(timeIntervalSince1970: 1_759_990_000))
    }

    @Test func displayDateFallbackIsParisLocalTime() throws {
        let headers = try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.headerList)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris")!
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: try #require(headers[2].date))
        #expect(parts.year == 2025 && parts.month == 10 && parts.day == 3)
        #expect(parts.hour == 8 && parts.minute == 30)
    }

    @Test func senderUsesDisplayNameLikeIMAP() throws {
        let headers = try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.headerList)
        #expect(headers[0].from == "Mme Dupont")
        #expect(headers[1].from == "vie-scolaire@monlycee.net")
        #expect(headers[2].from == "M. Martin")
        #expect(MonLyceeMailParser.sender(from: "<seul@monlycee.net>") == "seul@monlycee.net")
        #expect(MonLyceeMailParser.sender(from: nil) == "")
    }

    @Test func blankSubjectGetsIMAPPlaceholder() throws {
        let headers = try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.headerList)
        #expect(headers[1].subject == "(sans objet)")
    }

    @Test func unreadDefaultsToFalse() throws {
        let headers = try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.headerList)
        #expect(headers.map(\.unread) == [true, false, false])
    }

    @Test func responseWithoutMailHeaderIsAnEmptyInbox() throws {
        #expect(try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.emptyInbox).isEmpty)
    }

    @Test func nonJSONIsInvalidPayload() {
        #expect(throws: MonLyceeMailError.invalidPayload) {
            try MonLyceeMailParser.headers(from: MonLyceeMailFixtures.loginPage)
        }
        #expect(throws: MonLyceeMailError.invalidPayload) {
            try MonLyceeMailParser.headers(from: Data(#"{"error": "session"}"#.utf8))
        }
    }

    @Test func bodyIsReducedToPlainText() throws {
        let body = try MonLyceeMailParser.body(from: MonLyceeMailFixtures.mail)
        #expect(body == "Bonjour,\nRendez-vous le 12 octobre & merci.\nL'équipe")
    }

    @Test func bodyWithoutMailObjectIsInvalidPayload() {
        #expect(throws: MonLyceeMailError.invalidPayload) {
            try MonLyceeMailParser.body(from: MonLyceeMailFixtures.emptyInbox)
        }
    }

    @Test func plainTextDropsScriptsAndCollapsesBlankLines() {
        let html = "<script>alert(1)</script><div>A</div><br><br><br><div>B</div>"
        #expect(MonLyceeMailParser.plainText(fromHTML: html) == "A\n\nB")
    }
}

// MARK: - Request building

@Suite("MonLyceeWebmailClient request building")
struct MonLyceeWebmailRequestTests {

    @Test func formEncodingEscapesReservedCharacters() {
        let encoded = MonLyceeWebmailClient.formEncode([("tok", "a+b=c&d/é"), ("q", "deux mots")])
        #expect(encoded == "tok=a%2Bb%3Dc%26d%2F%C3%A9&q=deux+mots")
    }

    @Test func requestTargetsMonLyceeAPIOnly() throws {
        let request = MonLyceeWebmailClient.formRequest(path: "getMail.json", params: [("tok", "t")])
        #expect(request.url?.absoluteString == "https://apis-mail.monlycee.net/webmail/xml/getMail.json")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://web-mail.monlycee.net")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(request.httpBody == Data("tok=t".utf8))
    }

    @Test func monLyceeDomainCheckIsSuffixBased() {
        #expect(MonLyceeWebmailClient.isMonLyceeDomain("monlycee.net"))
        #expect(MonLyceeWebmailClient.isMonLyceeDomain(".monlycee.net"))
        #expect(MonLyceeWebmailClient.isMonLyceeDomain("web-mail.MonLycee.net"))
        #expect(!MonLyceeWebmailClient.isMonLyceeDomain("monlycee.net.evil.com"))
        #expect(!MonLyceeWebmailClient.isMonLyceeDomain("faux-monlycee.net"))
        #expect(!MonLyceeWebmailClient.isMonLyceeDomain("monlycee.fr"))
    }
}

// MARK: - Mapping & dedupe

@Suite("MonLyceeMailService mapping & dedupe")
@MainActor
struct MonLyceeMailDedupeTests {

    private let day = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Family.self, Child.self, Message.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func header(_ id: Int = 7, from: String = "Mme Dupont", subject: String = "Réunion", date: Date? = nil) -> MonLyceeMailHeader {
        MonLyceeMailHeader(msgId: id, from: from, subject: subject, date: date ?? day, unread: true)
    }

    private func message(source: MessageSource, provider: String?, uid: String? = nil,
                         sender: String = "Mme Dupont", subject: String = "Réunion",
                         kind: MessageKind = .conversation, date: Date? = nil) -> Message {
        Message(sender: sender, subject: subject, body: "", date: date ?? day,
                source: source, kind: kind, imapUID: uid, imapProvider: provider)
    }

    @Test func mappingStampsSourceProviderUIDAndReadState() {
        let msg = MonLyceeMailService.makeMessage(from: header(1042), body: "Bonjour")
        #expect(msg.source == .monlycee)
        #expect(msg.kind == .conversation)
        #expect(msg.imapUID == "1042")
        #expect(msg.imapProvider == MonLyceeMailService.providerTag)
        #expect(msg.read == false)
        #expect(msg.body == "Bonjour")
        #expect(msg.date == day)
    }

    @Test func missingDateFallsBackToNow() {
        let undated = MonLyceeMailHeader(msgId: 1, from: "a", subject: "b", date: nil, unread: false)
        let msg = MonLyceeMailService.makeMessage(from: undated, body: "")
        #expect(abs(msg.date.timeIntervalSinceNow) < 5)
        #expect(msg.read == true)
    }

    @Test func sameWebmailIdIsDuplicate() {
        let existing = [message(source: .monlycee, provider: MonLyceeMailService.providerTag, uid: "7")]
        #expect(MonLyceeMailService.isDuplicate(header(7), among: existing))
        #expect(!MonLyceeMailService.isDuplicate(header(8, subject: "Autre"), among: existing))
    }

    @Test func sameMailAlreadyFetchedOverMonLyceeIMAPIsDuplicate() {
        // Different id namespace ("31" is an IMAP UID), same mail.
        let existing = [message(source: .imap, provider: "monlycee", uid: "31",
                                sender: "mme dupont ", subject: "REUNION",
                                date: day.addingTimeInterval(3600))]
        #expect(MonLyceeMailService.isDuplicate(header(7), among: existing))
    }

    @Test func monLyceeIMAPOnAnotherDayIsNotDuplicate() {
        let existing = [message(source: .imap, provider: "monlycee", date: day.addingTimeInterval(-3 * 86_400))]
        #expect(!MonLyceeMailService.isDuplicate(header(7), among: existing))
    }

    @Test func otherSourcesAreNeverAbsorbed() {
        let existing = [
            message(source: .imap, provider: "gmail"),
            message(source: .imap, provider: nil),
            message(source: .ent, provider: nil, uid: "7"),
            message(source: .pronote, provider: nil, uid: "7"),
            message(source: .imap, provider: "monlycee", kind: .schoolbook),
        ]
        #expect(!MonLyceeMailService.isDuplicate(header(7), among: existing))
    }

    @Test func undatedHeaderOnlyMatchesById() {
        let undated = MonLyceeMailHeader(msgId: 7, from: "Mme Dupont", subject: "Réunion", date: nil, unread: false)
        #expect(!MonLyceeMailService.isDuplicate(undated, among: [message(source: .imap, provider: "monlycee")]))
    }

    @Test func persistedMessageKeepsMonLyceeSource() throws {
        let ctx = try makeContext()
        let child = Child(firstName: "Gaston", level: .lycee, grade: "2nde", schoolType: .ent, establishment: "Lycée Test")
        ctx.insert(child)
        let msg = MonLyceeMailService.makeMessage(from: header(9), body: "x")
        msg.child = child
        ctx.insert(msg)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Message>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.source == .monlycee)
        #expect(MonLyceeMailService.isDuplicate(header(9), among: child.messages))
    }

    @Test func imapGateOnlyStepsAsideForMonLyceeIMAP() {
        #expect(MonLyceeMailService.shouldSync(configuredIMAPProviderIDs: []))
        #expect(MonLyceeMailService.shouldSync(configuredIMAPProviderIDs: ["gmail", "outlook"]))
        #expect(!MonLyceeMailService.shouldSync(configuredIMAPProviderIDs: ["gmail", "monlycee"]))
    }
}
