import Foundation
import SwiftData
import SwiftUI

// MARK: - Preview Container

/// In-memory SwiftData container pre-populated with realistic sample data.
/// Use in #Preview { SomeView().modelContainer(PreviewData.container) }
@MainActor
enum PreviewData {

    static let container: ModelContainer = {
        let schema = Schema([Family.self, Child.self, Grade.self, ScheduleEntry.self,
                             Homework.self, Message.self, Insight.self, SchoolPhoto.self,
                             CultureReco.self, Curriculum.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
        populate(container.mainContext)
        return container
    }()

    // MARK: - Sample children (accessible for individual views)

    static let lea: Child = {
        let c = Child(firstName: "Léa", level: .college, grade: "4e",
                      schoolType: .pronote, establishment: "Collège Victor Hugo")
        return c
    }()

    static let tom: Child = {
        let c = Child(firstName: "Tom", level: .elementaire, grade: "CM2",
                      schoolType: .ent, establishment: "École Jean Moulin")
        c.entProvider = .pcn
        return c
    }()

    // MARK: - Populate

    private static func populate(_ ctx: ModelContext) {
        let family = Family(parentName: "Marie")
        ctx.insert(family)

        // --- Léa (collège, Pronote) ---
        let lea = Child(firstName: "Léa", level: .college, grade: "4e",
                        schoolType: .pronote, establishment: "Collège Victor Hugo")
        family.children.append(lea)
        ctx.insert(lea)

        // Grades
        addGrades(to: lea, ctx: ctx)

        // Schedule (today)
        addSchedule(to: lea, ctx: ctx)

        // Homework
        addHomework(to: lea, ctx: ctx)

        // Messages
        addMessages(to: lea, ctx: ctx)

        // --- Tom (élémentaire, ENT) ---
        let tom = Child(firstName: "Tom", level: .elementaire, grade: "CM2",
                        schoolType: .ent, establishment: "École Jean Moulin")
        tom.entProvider = .pcn
        tom.entChildId = "ent-tom-001"
        family.children.append(tom)
        ctx.insert(tom)

        // Messages (schoolbook)
        let carnet = Message(sender: "Mme Petit", subject: "Sortie scolaire le 15 avril",
                             body: "<p>Merci de signer l'autorisation pour la sortie au musée d'Orsay le 15 avril. Rendez-vous à 8h30 devant l'école.</p>",
                             date: .now.addingTimeInterval(-3600 * 5),
                             source: .ent, kind: .schoolbook)
        carnet.link = "49824"
        carnet.child = tom
        ctx.insert(carnet)

        let msgTom = Message(sender: "Direction", subject: "Grève nationale du 17 avril",
                             body: "L'école sera fermée le mercredi 17 avril en raison d'une grève nationale.",
                             date: .now.addingTimeInterval(-3600 * 26),
                             source: .ent)
        msgTom.read = true
        msgTom.child = tom
        ctx.insert(msgTom)

        try? ctx.save()
    }

    // MARK: - Helpers

    private static func addGrades(to child: Child, ctx: ModelContext) {
        let subjects: [(String, Double, Double, Double?)] = [
            ("Mathématiques", 14.5, 20, 12.3),
            ("Français",      13.0, 20, 11.8),
            ("Histoire-Géo",  16.0, 20, 13.5),
            ("SVT",           15.5, 20, 14.0),
            ("Anglais",       17.0, 20, 13.2),
            ("Physique",      11.5, 20, 10.8),
            ("Mathématiques", 12.0, 20, 12.3),
            ("Français",      15.5, 20, 11.8),
        ]
        var offset = 0
        for (subj, val, outOf, avg) in subjects {
            let g = Grade(subject: subj, value: val, outOf: outOf, coefficient: 2,
                          date: .now.addingTimeInterval(-Double(offset) * 86400 * 5))
            g.classAverage = avg
            g.child = child
            ctx.insert(g)
            offset += 1
        }
    }

    private static func addSchedule(to child: Child, ctx: ModelContext) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let slots: [(String, Int, Int, Int, String)] = [
            ("Mathématiques", 8, 0, 9, "Salle 204"),
            ("Français",      9, 0, 10, "Salle 108"),
            ("Histoire-Géo",  10, 15, 11, "Salle 112"),
            ("SVT",           13, 30, 14, "Labo"),
            ("Anglais",       14, 0, 15, "Salle 204"),
        ]
        for (subj, startH, startM, endH, room) in slots {
            let start = cal.date(bySettingHour: startH, minute: startM, second: 0, of: today)!
            let end = cal.date(bySettingHour: endH, minute: 0, second: 0, of: today)!
            let entry = ScheduleEntry(subject: subj, start: start, end: end)
            entry.room = room
            entry.child = child
            ctx.insert(entry)
        }
        // One cancelled class tomorrow
        let tomorrow = today.addingTimeInterval(86400)
        let cancelled = ScheduleEntry(
            subject: "Physique",
            start: cal.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!,
            end: cal.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow)!,
            cancelled: true
        )
        cancelled.child = child
        ctx.insert(cancelled)
    }

    private static func addHomework(to child: Child, ctx: ModelContext) {
        let items: [(String, String, TimeInterval)] = [
            ("Mathématiques", "Exercices 12 à 18 page 47 — équations du second degré", 86400),
            ("Français",      "Rédiger une analyse du chapitre 4 de L'Étranger (15 lignes min.)", 86400 * 2),
            ("Histoire-Géo",  "Apprendre la leçon sur la Première Guerre mondiale", 86400 * 3),
            ("Anglais",       "Vocabulary list Unit 6 — learn 20 words", 86400 * 4),
        ]
        for (subj, desc, offset) in items {
            let hw = Homework(subject: subj, description: desc,
                              dueDate: .now.addingTimeInterval(offset))
            hw.child = child
            ctx.insert(hw)
        }
    }

    private static func addMessages(to child: Child, ctx: ModelContext) {
        let msgs: [(String, String, String, TimeInterval, Bool)] = [
            ("M. Bernard", "Résultats du contrôle de maths",
             "Bonjour, les résultats du contrôle du 4 avril sont disponibles sur Pronote. La moyenne de la classe est 12,3/20.", -3600 * 2, false),
            ("Mme Leblanc", "Réunion parents-professeurs",
             "La réunion parents-professeurs aura lieu le 25 avril de 17h à 19h30 en salle polyvalente.", -86400, true),
            ("Administration", "Absence du 8 avril",
             "Votre enfant a été absent le 8 avril (matin). Merci de nous faire parvenir le justificatif.", -86400 * 3, true),
        ]
        for (sender, subject, body, offset, read) in msgs {
            let msg = Message(sender: sender, subject: subject, body: body,
                              date: .now.addingTimeInterval(offset), source: .pronote)
            msg.read = read
            msg.child = child
            ctx.insert(msg)
        }
    }
}

// MARK: - Convenience modifier

extension View {
    /// Inject the preview SwiftData container.
    func withPreviewData() -> some View {
        modelContainer(PreviewData.container)
    }
}
