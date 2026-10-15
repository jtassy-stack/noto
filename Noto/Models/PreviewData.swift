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
                             CultureReco.self, Curriculum.self,
                             QuizItem.self, QuizAttempt.self, NotionMastery.self])
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

        // Révisions (child mode): a few reviewed 4e questions, one passed
        // quiz today and one notion in progress.
        addQuizSamples(for: lea, ctx: ctx)

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

        // Sample photos (public URLs — no auth, for UI testing in simulator)
        let photoSources: [(String, String, String)] = [
            ("https://picsum.photos/seed/noto1/600/600", "Sortie au Jardin des Plantes", "Mme Martin"),
            ("https://picsum.photos/seed/noto2/600/600", "Atelier peinture", "M. Dupont"),
            ("https://picsum.photos/seed/noto3/600/600", "Projet potager", "Mme Martin"),
            ("https://picsum.photos/seed/noto4/600/600", "Carnaval de l'école", "Direction"),
            ("https://picsum.photos/seed/noto5/600/600", "Spectacle de Noël", "Mme Petit"),
        ]
        for (url, title, author) in photoSources {
            let photo = SchoolPhoto(entPath: url, source: .blog, title: title, authorName: author,
                                   date: .now.addingTimeInterval(-Double.random(in: 0...86400 * 30)))
            photo.child = tom
            ctx.insert(photo)
        }

        try? ctx.save()
    }

    // MARK: - Révisions samples

    /// Léa as inserted in `container` (`lea` above is a detached instance).
    static var revisionChild: Child {
        let children = (try? container.mainContext.fetch(FetchDescriptor<Child>())) ?? []
        return children.first { $0.firstName == "Léa" } ?? children[0]
    }

    /// A 4e child and no question at all: the « questions arrivent bientôt » state.
    static let emptyBankContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Schema(NotoSchemaV1.models), configurations: config)
        let family = Family(parentName: "Marie")
        container.mainContext.insert(family)
        let child = Child(firstName: "Léa", level: .college, grade: "4e",
                          schoolType: .pronote, establishment: "Collège Victor Hugo")
        family.children.append(child)
        container.mainContext.insert(child)
        try? container.mainContext.save()
        return container
    }()

    /// Reviewed 4e items on real `curriculum.json` themes (subject + theme
    /// verbatim) so previews go through `QuizSession`'s matching path.
    static let sampleQuizItems: [(subject: String, theme: String, question: String,
                                  choices: [String], answer: Int, explanation: String)] = [
        ("Mathématiques", "Théorème de Pythagore et triangles",
         "Dans un triangle rectangle, comment s'appelle le côté opposé à l'angle droit ?",
         ["La médiane", "L'hypoténuse", "La bissectrice", "La hauteur"], 1,
         "L'hypoténuse est le plus grand côté du triangle rectangle."),
        ("Mathématiques", "Calcul littéral et équations",
         "Quelle est la solution de l'équation 2x + 3 = 11 ?",
         ["x = 4", "x = 7", "x = 3", "x = 5,5"], 0,
         "2x = 11 − 3 = 8, donc x = 8 ÷ 2 = 4."),
        ("Français", "La fiction pour interroger le réel — réalisme et naturalisme",
         "Quel écrivain est le chef de file du naturalisme ?",
         ["Victor Hugo", "Molière", "Émile Zola", "Jean de La Fontaine"], 2,
         "Émile Zola a écrit la série des Rougon-Macquart, dont « Germinal »."),
        ("Histoire", "Le XVIIIe siècle : expansions, Lumières et révolutions",
         "En quelle année a lieu la prise de la Bastille ?",
         ["1715", "1804", "1848", "1789"], 3,
         "Le 14 juillet 1789, les Parisiens prennent la Bastille."),
        ("SVT", "Le vivant et son évolution — reproduction et évolution",
         "Quel scientifique a proposé la théorie de l'évolution par la sélection naturelle ?",
         ["Charles Darwin", "Louis Pasteur", "Isaac Newton", "Marie Curie"], 0,
         "Darwin publie « L'Origine des espèces » en 1859."),
        ("Physique-Chimie", "Des signaux pour observer et communiquer — lumière et son",
         "Dans quel milieu le son ne peut-il pas se propager ?",
         ["Dans l'eau", "Dans l'air", "Dans le vide", "Dans le métal"], 2,
         "Le son a besoin de matière pour se propager : il ne traverse pas le vide."),
    ]

    private static func addQuizSamples(for child: Child, ctx: ModelContext) {
        var keys: [String] = []
        for (index, sample) in sampleQuizItems.enumerated() {
            let key = QuizKey.make(question: sample.question, choices: sample.choices)
            keys.append(key)
            let item = QuizItem(
                id: QuizKey.deterministicID(for: key), questionKey: key, kind: "programme",
                question: sample.question, choices: sample.choices, answerIndex: sample.answer,
                explanation: sample.explanation, domain: "programme", difficulty: 1,
                level: "4e", subject: sample.subject, theme: sample.theme,
                source: .bank, sourceRef: "preview/4e#\(index)", reviewed: true, fetchedAt: .now
            )
            ctx.insert(item)
        }

        let attempt = QuizAttempt(
            child: child, date: .now.addingTimeInterval(-3600), itemIDs: [],
            questionKeys: Array(keys.prefix(5)), answers: [1, 0, 2, 3, 1],
            correctCount: 4, totalCount: 5, durationSec: 140, minutesEarned: 10, bonusApplied: false
        )
        ctx.insert(attempt)
        let yesterday = QuizAttempt(
            child: child, date: .now.addingTimeInterval(-86400), itemIDs: [],
            questionKeys: Array(keys.suffix(5)), answers: [0, 2, 3, 0, 2],
            correctCount: 5, totalCount: 5, durationSec: 120, minutesEarned: 10, bonusApplied: false
        )
        ctx.insert(yesterday)

        let mastery = NotionMastery(
            child: child,
            notionKey: NotionKey.make(level: "4e", subject: "Mathématiques", theme: "Théorème de Pythagore et triangles"),
            now: .now, calendar: .current
        )
        mastery.leitnerBox = 3
        ctx.insert(mastery)
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
