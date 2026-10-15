import Foundation
@testable import Noto

/// Shared clock and fixtures for the quiz suites. `now` is
/// 2023-11-14 23:13:20 Europe/Paris: late in the evening, so "tomorrow
/// midnight" is less than an hour away and any `now + 24 h` shortcut would
/// be caught. Every fixture date goes through `QuizClock.calendar`.
enum QuizClock {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    /// `dayOffset` days after today (Paris), at `hour:minute`.
    static func date(day dayOffset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let start = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!
    }

    static func homework(_ subject: String, _ text: String, day: Int, hour: Int = 0, minute: Int = 0,
                         done: Bool = false) -> HomeworkSnapshot {
        HomeworkSnapshot(subject: subject, descriptionText: text, dueDate: date(day: day, hour: hour, minute: minute),
                         done: done, calendar: calendar)
    }
}

/// Small, hand-written programmes (4e, 1re with spécialités, CM2) so the
/// selector tests do not depend on the bundled `curriculum.json`.
enum QuizCurriculumFixtures {
    static let francais4e = CurriculumSubject(name: "Français", themes: [
        CurriculumTheme(theme: "Molière et le théâtre classique", keywords: ["molière", "scapin", "comédie"], period: "Trimestre 1"),
        CurriculumTheme(theme: "Le récit fantastique", keywords: ["fantastique", "horla", "maupassant"], period: "Trimestre 2"),
        CurriculumTheme(theme: "Dire l'amour", keywords: ["poème", "lyrique"], period: nil),
    ])
    static let maths4e = CurriculumSubject(name: "Mathématiques", themes: [
        CurriculumTheme(theme: "Théorème de Pythagore", keywords: ["pythagore", "hypoténuse"], period: "Année"),
        CurriculumTheme(theme: "Calcul littéral et équations", keywords: ["équation", "inconnue"], period: "Trimestre 2"),
    ])
    static let histoire4e = CurriculumSubject(name: "Histoire", themes: [
        CurriculumTheme(theme: "La Révolution française", keywords: ["révolution", "1789"], period: "Trimestre 1"),
    ])
    static let geographie4e = CurriculumSubject(name: "Géographie", themes: [
        CurriculumTheme(theme: "L'urbanisation du monde", keywords: ["urbanisation", "métropole"], period: "Année"),
    ])

    static let programs: [CurriculumProgram] = [
        CurriculumProgram(level: "4e", cycle: 4, subjects: [francais4e, maths4e, histoire4e, geographie4e]),
        CurriculumProgram(level: "1re", cycle: 0, subjects: [
            CurriculumSubject(name: "Français", themes: [
                CurriculumTheme(theme: "La poésie du XIXe au XXIe siècle", keywords: ["baudelaire", "spleen"], period: "Année"),
            ]),
            CurriculumSubject(name: "HGGSP", track: .specialite, specialty: "HGGSP", themes: [
                CurriculumTheme(theme: "Comprendre un régime politique : la démocratie", keywords: ["démocratie"], period: "Année"),
            ]),
            CurriculumSubject(name: "SES", track: .specialite, specialty: "SES", themes: [
                CurriculumTheme(theme: "Comment un marché concurrentiel fonctionne-t-il ?", keywords: ["marché", "prix"], period: "Année"),
            ]),
        ]),
        CurriculumProgram(level: "CM2", cycle: 3, subjects: [
            CurriculumSubject(name: "Français", themes: [
                CurriculumTheme(theme: "Lire des contes", keywords: ["conte"], period: "Année"),
            ]),
        ]),
    ]

    static let curriculum = CurriculumSnapshot(programs: programs)
}
