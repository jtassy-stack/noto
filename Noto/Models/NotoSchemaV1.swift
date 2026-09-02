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
        ]
    }
}
