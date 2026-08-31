import Foundation
import SwiftData

/// Baseline versioned schema (V1) for the nōto SwiftData model graph.
/// Mirrors the model list previously passed inline to `.modelContainer(for:)`
/// in `NotoApp.swift`. Introduced to enable `SchemaMigrationPlan`-based
/// migrations going forward — no migration stages exist yet since this is
/// the first tracked version.
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

/// Migration plan for the nōto SwiftData store. Currently a single baseline
/// version (`NotoSchemaV1`) with no migration stages — add stages here when
/// a future schema version is introduced.
enum NotoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [NotoSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
