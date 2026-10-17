import Foundation
import SwiftData

/// Versioned schema for the nōto SwiftData model graph.
/// Mirrors the model list previously passed inline to `.modelContainer(for:)`
/// in `NotoApp.swift`.
///
/// This schema references the live model types, which are edited in place
/// whenever a field is added (Skolengo fields, `Child.lastSyncedAt`, …). That
/// is fine for SwiftData's automatic lightweight migration, which is what
/// `NotoApp` relies on, but it is NOT a frozen snapshot: a
/// `SchemaMigrationPlan` compares the on-disk store against every schema it
/// lists, and a store written by an older shape of "V1" no longer matches,
/// so staged migration fails at launch with "unknown model version".
///
/// To introduce staged migrations later, first freeze the current models as
/// copies nested inside this enum (`NotoSchemaV1.Child`, …), point the app at
/// a new `NotoSchemaV2`, and only then add a plan with a V1 → V2 stage.
enum NotoSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            Family.self,
            Child.self,
            Grade.self,
            ScheduleEntry.self,
            Homework.self,
            Message.self,
            Curriculum.self,
            CultureReco.self,
            Insight.self,
            MeetingNote.self,
            ExtractedItem.self,
            // Previously reached only through `Child.photos`; listed so a
            // future V1 freeze cannot miss it.
            SchoolPhoto.self,
            // Révisions (Phase 3.1). New entities are a lightweight-migration
            // case: appended in place, no V2 and no migration plan (see above).
            QuizItem.self,
            QuizAttempt.self,
            NotionMastery.self,
            // Gamification (Phase 3.6), same lightweight rule: a new entity
            // appended here, plus additive fields with inline defaults on an
            // existing one (`QuizAttempt.itemSubjects` / `itemXP`,
            // `Child.streakJokers`, `NotionMastery.masteredAt`). A rename, a type change or a field
            // without default would need the V2 freeze described above.
            StreakJoker.self,
            // Parent quiz on the child's programme: new entity, same rule.
            ParentQuizAttempt.self,
            // Programme position (Phase 3.8): new entity appended, lightweight
            // (every field defaulted), plus defaulted `Child.programmeLevel` /
            // `lessonContentsFetchedAt` and the `Child.lessonContents` to-many.
            LessonContent.self,
        ]
    }
}
