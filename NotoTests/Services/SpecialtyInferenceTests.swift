import Testing
import Foundation
import SwiftData
@testable import Noto

/// `CurriculumService.inferSpecialties` against realistic Pronote label sets.
/// Uses an in-memory 1re / Tle fixture shaped like `curriculum.json` (never
/// the bundled file).
@Suite("Spécialités inference")
struct SpecialtyInferenceTests {

    private static func subject(_ name: String, _ track: CurriculumTrack) -> CurriculumSubject {
        CurriculumSubject(
            name: name,
            track: track,
            specialty: track == .specialite ? name : nil,
            themes: []
        )
    }

    private static let specialites = ["Mathématiques", "Physique-Chimie", "SVT", "NSI", "SI",
                                      "SES", "HGGSP", "HLP", "LLCER Anglais"]

    /// Computed (fresh instance per use): CurriculumService is not Sendable,
    /// so a shared `static let` is rejected under Swift 6 strict concurrency.
    private static var service: CurriculumService {
        let premiere = ["Français", "Histoire", "Géographie", "EMC", "Enseignement scientifique",
                        "Mathématiques", "Anglais"].map { subject($0, .troncCommun) }
            + specialites.map { subject($0, .specialite) }
        let terminale = ["Philosophie", "Histoire", "Géographie", "EMC", "Enseignement scientifique",
                         "Anglais"].map { subject($0, .troncCommun) }
            + specialites.map { subject($0, .specialite) }
        let seconde = ["Français", "Mathématiques", "Physique-Chimie", "SVT", "SES", "SNT"]
            .map { subject($0, .troncCommun) }
        return CurriculumService(programs: [
            CurriculumProgram(level: "2nde", cycle: 0, subjects: seconde),
            CurriculumProgram(level: "1re", cycle: 0, subjects: premiere),
            CurriculumProgram(level: "Tle", cycle: 0, subjects: terminale),
        ])
    }

    /// Common tronc-commun labels every lycéen has.
    private static let tronc = ["FRANCAIS", "HISTOIRE-GEOGRAPHIE", "ANGLAIS LV1", "ESPAGNOL LV2",
                                "ENS. MORAL & CIVIQUE", "ENSEIGN.SCIENTIFIQUE", "ED.PHYSIQUE & SPORT."]

    @Test("1re scientific profile: maths + physique-chimie + NSI")
    func premiereScientifique() {
        let labels = Self.tronc + ["MATHEMATIQUES", "PHYSIQUE-CHIMIE", "NUMERIQUE SC.INFORM."]
        #expect(Self.service.inferSpecialties(level: "1re", subjectLabels: labels)
                == ["Mathématiques", "Physique-Chimie", "NSI"])
    }

    @Test("1re humanities profile: HGGSP + SES + LLCER, no maths")
    func premiereHumanites() {
        let labels = Self.tronc + ["HIST.GEO.GEOPOL.&SC.POL.", "SC. ECONO.& SOCIALES", "LLC ANGL.MOND.CONT."]
        #expect(Self.service.inferSpecialties(level: "1re", subjectLabels: labels)
                == ["SES", "HGGSP", "LLCER Anglais"])
    }

    @Test("Tle: HLP + SI, labels repeated across schedule / grades / homework")
    func terminale() {
        let labels = Self.tronc + ["PHILOSOPHIE", "HUMAN.LITTER.PHILO.", "SC. INGENIEUR",
                                   "SC. INGENIEUR", "HUMAN.LITTER.PHILO."]
        #expect(Self.service.inferSpecialties(level: "Tle", subjectLabels: labels) == ["SI", "HLP"])
    }

    @Test("Raw persisted level still infers (TG2 → Tle)")
    func rawLevel() {
        #expect(Self.service.inferSpecialties(level: "TG2", subjectLabels: ["SVT", "SES"]) == ["SVT", "SES"])
    }

    @Test("Enseignement scientifique alone adds no specialty")
    func enseignementScientifique() {
        #expect(Self.service.inferSpecialties(level: "1re", subjectLabels: Self.tronc).isEmpty)
        #expect(Self.service.inferSpecialties(level: "Tle", subjectLabels: ["ENSEIGNEMENT SCIENTIFIQUE"]).isEmpty)
    }

    @Test("Maths complémentaires in Tle does not imply spé maths")
    func mathsComplementaires() {
        let labels = Self.tronc + ["MATHS COMPLEMENTAIRES", "SC. ECONO.& SOCIALES"]
        #expect(Self.service.inferSpecialties(level: "Tle", subjectLabels: labels) == ["SES"])
    }

    @Test("Spé markers and short codes match on exact label only")
    func spePrefixedLabels() {
        let labels = ["SPE NSI", "SPE MATHS", "PHYSIQUE"]
        #expect(Self.service.inferSpecialties(level: "1re", subjectLabels: labels) == ["Mathématiques", "NSI"])
    }

    @Test("Anglais tronc commun never infers LLCER")
    func anglaisIsNotLLCER() {
        #expect(Self.service.inferSpecialties(level: "1re", subjectLabels: ["ANGLAIS", "ANGLAIS LV1"]).isEmpty)
    }

    @Test("Non-spécialité levels return []", arguments: ["2nde", "3e", "CM2", "", "?"])
    func otherLevels(level: String) {
        let labels = ["MATHEMATIQUES", "PHYSIQUE-CHIMIE", "SVT", "SC. ECONO.& SOCIALES"]
        #expect(Self.service.inferSpecialties(level: level, subjectLabels: labels).isEmpty)
    }

    @Test("No labels → []")
    func empty() {
        #expect(Self.service.inferSpecialties(level: "1re", subjectLabels: []).isEmpty)
    }

    @Test("An unaliased spé label is missed next to an aliased one")
    func unaliasedNextToAliased() {
        let labels = ["MATHEMATIQUES", "SCIENCES INGENIEUR"]
        #expect(Self.service.inferSpecialties(level: "Tle", subjectLabels: labels) == ["Mathématiques"])
    }

    // MARK: - Child.refreshInferredSpecialties (persistence gate)

    private func makeChild(grade: String, specialties: [String] = []) throws -> (ModelContext, Child) {
        let container = try ModelContainer(
            for: Schema([Family.self, Child.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let child = Child(firstName: "Test", level: .lycee, grade: grade,
                          schoolType: .pronote, establishment: "Lycée Test")
        child.specialties = specialties
        context.insert(child)
        return (context, child)
    }

    private func addCourses(_ subjects: [String], to child: Child, in context: ModelContext) {
        for subject in subjects {
            let entry = ScheduleEntry(subject: subject, start: .now, end: .now.addingTimeInterval(3600))
            context.insert(entry)
            child.schedule.append(entry)
        }
    }

    private func addHomework(_ subjects: [String], to child: Child, in context: ModelContext) {
        for subject in subjects {
            let hw = Homework(subject: subject, description: "", dueDate: .now)
            context.insert(hw)
            child.homework.append(hw)
        }
    }

    @Test("Incomplete inference (unaliased spé missed) is not persisted")
    func incompleteNotPersisted() throws {
        let (context, child) = try makeChild(grade: "Tle")
        addCourses(Self.tronc + ["MATHEMATIQUES", "SCIENCES INGENIEUR"], to: child, in: context)
        child.refreshInferredSpecialties(using: Self.service)
        #expect(child.specialties.isEmpty)
    }

    @Test("A complete schedule-backed inference is persisted")
    func completePersisted() throws {
        let (context, child) = try makeChild(grade: "Tle")
        addCourses(Self.tronc + ["PHILOSOPHIE", "HUMAN.LITTER.PHILO.", "SC. INGENIEUR"], to: child, in: context)
        child.refreshInferredSpecialties(using: Self.service)
        #expect(child.specialties == ["SI", "HLP"])
    }

    @Test("A schedule drops a spé no longer taken")
    func scheduleReplaces() throws {
        let (context, child) = try makeChild(grade: "Tle", specialties: ["Mathématiques", "Physique-Chimie", "SVT"])
        addCourses(["MATHEMATIQUES", "PHYSIQUE-CHIMIE"], to: child, in: context)
        child.refreshInferredSpecialties(using: Self.service)
        #expect(child.specialties == ["Mathématiques", "Physique-Chimie"])
    }

    @Test("Homework-only evidence never shrinks a known list")
    func homeworkOnlyNeverShrinks() throws {
        let (context, child) = try makeChild(grade: "Tle", specialties: ["Mathématiques", "SVT"])
        addHomework(["SVT"], to: child, in: context)
        child.refreshInferredSpecialties(using: Self.service)
        #expect(child.specialties == ["Mathématiques", "SVT"])
    }

    @Test("Rows deleted in the same unsaved sync are ignored")
    func pendingDeletesIgnored() throws {
        let (context, child) = try makeChild(grade: "Tle")
        addCourses(["SVT"], to: child, in: context)
        try context.save()
        for entry in child.schedule { context.delete(entry) }
        addCourses(["MATHEMATIQUES", "PHYSIQUE-CHIMIE"], to: child, in: context)
        child.refreshInferredSpecialties(using: Self.service)
        #expect(child.specialties == ["Mathématiques", "Physique-Chimie"])
    }
}
