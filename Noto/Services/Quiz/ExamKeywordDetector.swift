import Foundation

/// Detects an upcoming test ("contrôle", "DS", "interro", …) from homework
/// labels and timetable flags. Pure: used by `RewardPolicy` (exam-eve bonus)
/// and the quiz source selection.
enum ExamKeywordDetector {
    enum Rule: Sendable, Equatable {
        /// A whole folded token from the set. Explicit forms, never a prefix
        /// or a substring: "interroger" and "contrôler" are not exams.
        case token(Set<String>)
        /// A token equal to the word, optionally followed by digits only
        /// ("ds", "DS2"; not "dsl", not "fonds").
        case numbered(String)
        /// Contiguous folded tokens ("bac blanc", not "bac" alone).
        case phrase(String)
    }

    static let keywords: [Rule] = [
        .token(["controle", "controles"]),
        .token(["evaluation", "evaluations"]),
        .numbered("ds"),
        .token(["interro", "interros", "interrogation", "interrogations"]),
        .phrase("bac blanc"),
        // Suggestion, pending Julien's decision (design brief A.5):
        // .phrase("devoir surveille"),
    ]

    /// A keyword token right after one of these is not an exam
    /// ("auto-évaluation", "auto évaluation").
    static let negatingPrefixTokens: Set<String> = ["auto"]

    /// True when `text` contains one of the exam keywords, case- and
    /// accent-insensitively (`SubjectAlias.tokens` folds).
    static func matches(_ text: String) -> Bool {
        let tokens = SubjectAlias.tokens(text)
        func counts(at index: Int) -> Bool {
            index == 0 || !negatingPrefixTokens.contains(tokens[index - 1])
        }
        return keywords.contains { rule in
            switch rule {
            case .token(let forms):
                return tokens.indices.contains { forms.contains(tokens[$0]) && counts(at: $0) }
            case .numbered(let word):
                return tokens.contains { token in
                    token.hasPrefix(word) && token.dropFirst(word.count).allSatisfy(\.isNumber)
                }
            case .phrase(let phrase):
                return CurriculumService.containsSequence(tokens, SubjectAlias.tokens(phrase))
            }
        }
    }

    /// An exam is planned for the calendar day after `now`: a not-done
    /// homework due that day whose label matches, or a non-cancelled test
    /// lesson that day. Calendar days, never `now + 24 h`: ENT, MonLycée and
    /// École Directe stamp due dates at local midnight.
    static func hasExamTomorrow(homework: [HomeworkSnapshot], schedule: [ScheduleSnapshot],
                                now: Date, calendar: Calendar) -> Bool {
        let tomorrow = calendar.quizStartOfDay(addingDays: 1, to: now)
        let fromHomework = homework.contains {
            !$0.done && calendar.isDate($0.dueDate, inSameDayAs: tomorrow) && matches($0.descriptionText)
        }
        if fromHomework { return true }
        return schedule.contains {
            $0.isTest && !$0.cancelled && calendar.isDate($0.start, inSameDayAs: tomorrow)
        }
    }
}
