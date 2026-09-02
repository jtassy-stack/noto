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

    init(
        firstName: String,
        level: SchoolLevel,
        grade: String,
        schoolType: SchoolType,
        establishment: String,
        pawnoteID: String? = nil,
        rneCode: String? = nil
    ) {
        self.firstName = firstName
        self.level = level
        self.grade = grade
        self.schoolType = schoolType
        self.establishment = establishment
        self.pawnoteID = pawnoteID
        self.rneCode = rneCode
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
    func markSynced(at date: Date = .now) {
        lastSyncedAt = date
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
