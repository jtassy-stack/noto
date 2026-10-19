import Foundation
import SwiftData

enum SchoolType: String, Codable {
    case pronote
    case ent
    case ecoledirecte
    case skolengo
}

enum SchoolLevel: String, Codable, CaseIterable {
    case maternelle
    case elementaire = "élémentaire"
    case college = "collège"
    case lycee = "lycée"
}

@Model
final class Child {
    var firstName: String
    var avatar: Data?
    var level: SchoolLevel
    var grade: String // "6e", "CE1", "PS", etc.
    var schoolType: SchoolType
    var establishment: String
    /// Stable identifier returned by pawnote for Pronote children.
    /// Used as the primary dedupe key when a parent re-runs QR login.
    /// Nil for ENT children and for synthetic fallback children.
    var pawnoteID: String?
    var entChildId: String?        // ENT user ID (PCN/MonLycée) or élève ID (École Directe)
    var entProvider: ENTProvider?   // pcn or monlycee
    var edAccountId: String?       // École Directe famille account ID (from login response)
    var skolengoSchoolId: String?  // Skolengo school id — reconstructs SkolengoClient for background sync
    var skolengoEmsCode: String?   // Skolengo school emsCode — required API header, cached to avoid a re-search
    var skolengoUserId: String?    // Skolengo EMS user id for this élève (from the OIDC id_token's `sub` claim)
    var entClassName: String?      // Full class name from ENT (e.g. "CM1 - CM2 A - M. Lucas") for message filtering
    /// Répertoire National des Établissements code. Populated during
    /// onboarding from the directory API school picker (Phase 8.6).
    /// When present, `MailWhitelist.build` uses the celyn directory
    /// to fetch authoritative `mailDomains` (ENT + académie + commune
    /// services) instead of inferring from `establishment`.
    var rneCode: String?
    /// Timestamp of the last sync that ran to completion for this child
    /// (including a legitimately empty result). Nil until the first
    /// successful sync — the single source of truth for "first sync
    /// pending", regardless of which connector or view ran it.
    var lastSyncedAt: Date?
    /// Identifier of the dedicated EKCalendar nōto created for this child's
    /// emploi du temps, when the parent has opted in — see
    /// `ScheduleCalendarSyncService`. Nil means sync was never enabled.
    var eventKitCalendarIdentifier: String?
    var scheduleCalendarSyncEnabled: Bool = false
    /// Lycée spécialités (1re/Tle), canonical names as in `curriculum.json`
    /// ("Mathématiques", "HGGSP", "NSI", …). Empty = unknown → CurriculumService
    /// keeps every spécialité eligible. Default value keeps SwiftData's
    /// automatic lightweight migration working for existing stores.
    var specialties: [String] = []
    /// Canonical level (`CurriculumService.canonicalLevel(grade)`) the stored
    /// `lessonContents` were collected for. `LessonContentStore.purge` wipes
    /// them when it changes (new school year, class change). Defaulted for
    /// lightweight migration (Phase 3.8).
    var programmeLevel: String? = nil
    /// Last successful cahier de textes fetch (Pronote onglet 89, École
    /// Directe per-day). Lesson contents are refreshed at most every 24 h.
    var lessonContentsFetchedAt: Date? = nil
    /// Family sync (phase 9.2): the CloudKit zone shared between the parent's
    /// and the child's phones (« enfant-<uuid> », random, see
    /// `FamilySyncLink`). On the parent device the zone lives in the private
    /// database; on the child device it is a shared zone owned by the parent
    /// (`familySyncZoneOwner`). Nil = not linked. Defaulted for lightweight
    /// migration.
    var familySyncZoneName: String? = nil
    var familySyncZoneOwner: String? = nil
    /// When the child's device accepted the share (child side) or first sent
    /// data (parent side, set by the engine in 9.3).
    var familySyncLinkedAt: Date? = nil
    /// Last family sync that completed (phase 9.3), for « Synchronisé il y a… ».
    var familySyncLastSyncedAt: Date? = nil
    var family: Family?
    var createdAt: Date

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \Grade.child)
    var grades: [Grade]
    @Relationship(deleteRule: .cascade, inverse: \ScheduleEntry.child)
    var schedule: [ScheduleEntry]
    @Relationship(deleteRule: .cascade, inverse: \Homework.child)
    var homework: [Homework]
    @Relationship(deleteRule: .cascade, inverse: \Message.child)
    var messages: [Message]
    @Relationship(deleteRule: .cascade, inverse: \Insight.child)
    var insights: [Insight]
    @Relationship(deleteRule: .cascade, inverse: \SchoolPhoto.child)
    var photos: [SchoolPhoto]
    // Révisions (Phase 3.1). Inline defaults keep the additive to-many
    // relationships lightweight-migration compatible for existing stores.
    @Relationship(deleteRule: .cascade, inverse: \QuizAttempt.child)
    var quizAttempts: [QuizAttempt] = []
    @Relationship(deleteRule: .cascade, inverse: \NotionMastery.child)
    var notionMasteries: [NotionMastery] = []
    // Gamification (3.6): série jokers spent. Same additive pattern.
    @Relationship(deleteRule: .cascade, inverse: \StreakJoker.child)
    var streakJokers: [StreakJoker] = []
    // Parent quiz on the child's programme. Same additive pattern; never
    // read by rewards, XP or Leitner (`ParentQuizAttempt`).
    @Relationship(deleteRule: .cascade, inverse: \ParentQuizAttempt.child)
    var parentQuizAttempts: [ParentQuizAttempt] = []
    // Programme position (3.8): cahier de textes lessons + kept homework.
    // Local only, cascade-deleted with the child (RGPD).
    @Relationship(deleteRule: .cascade, inverse: \LessonContent.child)
    var lessonContents: [LessonContent] = []

    init(
        firstName: String,
        level: SchoolLevel,
        grade: String,
        schoolType: SchoolType,
        establishment: String,
        pawnoteID: String? = nil,
        rneCode: String? = nil,
        specialties: [String] = []
    ) {
        self.firstName = firstName
        self.level = level
        self.grade = grade
        self.schoolType = schoolType
        self.establishment = establishment
        self.pawnoteID = pawnoteID
        self.rneCode = rneCode
        self.specialties = specialties
        self.createdAt = .now
        self.grades = []
        self.schedule = []
        self.homework = []
        self.messages = []
        self.insights = []
        self.photos = []
    }
}

extension Child {
    /// QR-code Pronote login (pawnote bridge), as opposed to Pronote reached
    /// through an ENT SSO (MonLycée), which carries an `entProvider`.
    var isDirectPronote: Bool {
        schoolType == .pronote && entProvider == nil
    }

    /// True until a sync has completed once for this child. Drives the
    /// launch-time initial sync and the "première synchronisation" cards.
    var needsInitialSync: Bool {
        lastSyncedAt == nil
    }

    /// Record a completed sync. Called by every sync service on its
    /// success path (including the "empty payload, preserve" branch) so the
    /// stamp is set no matter which view triggered the sync.
    /// Also refreshes the 1re / Tle spécialités from the freshly synced
    /// subject labels — the one spot every connector goes through.
    func markSynced(at date: Date = .now) {
        lastSyncedAt = date
        refreshInferredSpecialties()
    }

    /// Generic fallback label when the stored establishment is URL-shaped.
    /// Prefers the ENT provider name when available, then a schoolType-derived label.
    private var genericSchoolLabel: String {
        switch schoolType {
        case .ent: return entProvider?.name ?? "ENT"
        case .ecoledirecte: return "École Directe"
        case .skolengo: return "Skolengo"
        default: return "École"
        }
    }

    /// Parent-facing label for the school. Masks raw URLs that leak from the
    /// refresh-token login path — parents should never see a server hostname.
    /// Case-insensitive on the scheme and host checks; RFC 3986 says both are.
    var displayEstablishment: String {
        let lowered = establishment.lowercased()
        // URL-shaped: mask the hostname regardless of parseability
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            if let host = URL(string: establishment)?.host?.lowercased(),
               host.contains("index-education") {
                return "Pronote"
            }
            return genericSchoolLabel
        }
        return establishment
    }

    /// Binary status used to paint per-child alert dots across the UI.
    /// Covers urgent homework (< 24h), unread messages, and recent low grades.
    /// Centralized so ChildSelectorBar and ChildStoryRing share the same rule.
    var hasAlert: Bool {
        let now = Date.now
        let in24h = now.addingTimeInterval(86_400)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
        let urgentHomework = homework.contains { !$0.done && $0.dueDate <= in24h }
        let unreadMessages = messages.contains { !$0.read }
        let recentLowGrade = grades.contains {
            $0.date >= sevenDaysAgo && $0.normalizedValue < 10
        }
        return urgentHomework || unreadMessages || recentLowGrade
    }
}
