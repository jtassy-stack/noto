import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "QuizGenerator")

// MARK: - Request / candidate (no FoundationModels types)

/// What the on-device model is asked to quiz on: ONE homework due within the
/// selector window (≤ 72 h), with the slot it fills. Everything the model
/// sees is in `sourceText`; nothing else about the child is sent, and the
/// request never leaves the device.
struct QuizGenerationRequest: Sendable, Equatable {
    /// Canonical level "6e" … "Tle".
    let level: String
    /// Slot subject (curriculum name when resolved, else the Pronote label).
    let subject: String
    /// Slot theme, nil when no curriculum theme matched the homework.
    let theme: String?
    let notionKey: String?
    /// `HomeworkSnapshot.dedupKey`, also the key of the generated question.
    let homeworkKey: String
    /// Raw Pronote subject label, as written in the homework.
    let homeworkSubject: String
    /// Homework description, cut to `maxHomeworkCharacters`.
    let homeworkText: String
    /// Due date in French ("jeudi 16 novembre").
    let dueDateText: String
    /// Right answers of the bank items of the same level / subject / theme:
    /// a generated answer equal to one of them is accepted even when the
    /// homework text does not contain it.
    let bankAnswers: [String]

    /// The on-device context window is 4096 tokens on iOS 26.
    static let maxHomeworkCharacters = 1500

    /// The only text the model gets, and the text answers are checked against.
    var sourceText: String {
        "Matière : \(homeworkSubject)\nPour le \(dueDateText)\n\(homeworkText)"
    }

    init(level: String, subject: String, theme: String?, notionKey: String?, homeworkKey: String,
         homeworkSubject: String, homeworkText: String, dueDateText: String, bankAnswers: [String]) {
        self.level = level
        self.subject = subject
        self.theme = theme
        self.notionKey = notionKey
        self.homeworkKey = homeworkKey
        self.homeworkSubject = homeworkSubject
        self.homeworkText = String(homeworkText.prefix(Self.maxHomeworkCharacters))
        self.dueDateText = dueDateText
        self.bankAnswers = bankAnswers
    }

    /// Request for a homework slot of `QuizSourceSelector`.
    init(level: String, slot: QuizPlanSlot, homework: HomeworkSnapshot, bankAnswers: [String],
         calendar: Calendar) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM"
        self.init(level: level, subject: slot.subject, theme: slot.theme, notionKey: slot.notionKey,
                  homeworkKey: homework.dedupKey, homeworkSubject: homework.subject,
                  homeworkText: homework.descriptionText, dueDateText: formatter.string(from: homework.dueDate),
                  bankAnswers: bankAnswers)
    }
}

/// One MCQ as the model returned it, before validation.
struct QuizCandidate: Sendable, Equatable {
    let question: String
    let choices: [String]
    let answerIndex: Int
    let explanation: String

    /// Builds the choices from the right answer and the wrong ones (the
    /// model writes them separately: its own `answerIndex` proved
    /// unreliable on device). The right answer goes at a position drawn
    /// from the question text: stable for a given question, not always first.
    static func assemble(question: String, correctAnswer: String, wrongAnswers: [String],
                         explanation: String) -> QuizCandidate {
        let position = QuizKey.normalizeName(question).unicodeScalars
            .reduce(0) { ($0 &+ Int($1.value)) % 9973 } % 4
        let index = min(position, wrongAnswers.count)
        var choices = wrongAnswers
        choices.insert(correctAnswer, at: index)
        return QuizCandidate(question: question, choices: choices, answerIndex: index, explanation: explanation)
    }
}

/// The generation step behind a protocol so `QuizSession` can be tested with
/// stubs: FoundationModels itself cannot run in unit tests.
/// `nil` = unavailable / failed / refused; the caller falls back silently.
protocol QuizGenerating: Sendable {
    func generate(_ request: QuizGenerationRequest) async -> [QuizCandidate]?
    /// Starts loading the model before the first request (non-blocking).
    func prewarm()
}

extension QuizGenerating {
    func prewarm() {}
}

// MARK: - Production chain

/// FoundationModels → bank. On iOS < 26, without Apple Intelligence, or when
/// the model is not ready or does not support French, returns nil at once
/// and the quiz is drawn from the bank only. No network call on any path:
/// the system model runs on device (the Private Cloud Compute model of the
/// iOS 27 SDK is never used here).
struct QuizGenerator: QuizGenerating {
    func generate(_ request: QuizGenerationRequest) async -> [QuizCandidate]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await FoundationModelsQuizGenerator().generate(request)
        }
        #endif
        return nil
    }

    /// Loads the on-device model ahead of the first `generate` (a cold
    /// system model otherwise spends part of the quiz budget loading).
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            FoundationModelsQuizGenerator.prewarm()
        }
        #endif
    }

    /// Questions generated per quiz, at most.
    static let maxGeneratedPerQuiz = 3
    /// Whole generation budget of one quiz (all homework slots together).
    static let defaultTimeout: Duration = .seconds(8)

    /// Runs `generator` on each request in order (one accepted question per
    /// homework slot, `maxGeneratedPerQuiz` in all) under ONE overall
    /// deadline, validates every candidate, and returns the accepted
    /// questions keyed by `homeworkKey`. A timeout, a nil result or a fully
    /// rejected batch simply leaves that slot to the bank.
    ///
    /// The questions are ephemeral: they are never written to `QuizItem`
    /// (the shared, non-personal bank). Only their `questionKey` / id end up
    /// in the child's `QuizAttempt`, which cascades with the `Child` (RGPD
    /// erasure, design brief C.4 item 15).
    static func questions(for requests: [QuizGenerationRequest], using generator: any QuizGenerating,
                          timeout: Duration = defaultTimeout,
                          clock: ContinuousClock = ContinuousClock()) async -> [String: QuizQuestion] {
        let deadline = clock.now.advanced(by: timeout)
        var result: [String: QuizQuestion] = [:]
        var usedKeys = Set<String>()
        for request in requests where result.count < maxGeneratedPerQuiz && result[request.homeworkKey] == nil {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            // Outer nil = the deadline won; inner nil = the generator gave nothing.
            let outcome: [QuizCandidate]?? = await AsyncTimeout.run(remaining) { () async -> [QuizCandidate]?? in
                Optional(await generator.generate(request))
            }
            guard let finished = outcome else {
                // The cancelled call may still hold the model: a new session
                // would queue behind it and burn the rest of the budget.
                break
            }
            guard let candidates = finished else { continue }
            let validation = QuizGenerationValidator.validate(candidates, request: request, maxCount: 1)
            if !validation.rejections.isEmpty {
                // Reasons only: never the homework text or the generated question.
                let reasons = validation.rejections.map(\.rawValue).joined(separator: ",")
                logger.info("Generated questions rejected: \(reasons, privacy: .public)")
            }
            guard let candidate = validation.accepted.first else { continue }
            let question = QuizGenerationValidator.question(from: candidate, request: request)
            // Same question on two homework: keep the first (the key is per homework).
            guard usedKeys.insert(QuizKey.make(question: question.question, choices: question.choices)).inserted
            else { continue }
            result[request.homeworkKey] = question
        }
        return result
    }
}

// MARK: - Validation (pure)

/// Post-validation of model output. The model is told to stay on the
/// homework text, but its output is untrusted: every question is checked
/// here, and anything doubtful is dropped (the slot then falls back to the
/// bank, which is always safe).
enum QuizGenerationValidator {
    enum Rejection: String, Sendable, Equatable {
        case emptyQuestion
        /// The stem is an instruction, not a question (no « ? »).
        case notAQuestion
        case tooLong
        case choiceCount
        case emptyChoice
        case duplicateChoices
        /// One choice contains another (« A, B et C » vs « B »): more than
        /// one choice can be read as right.
        case overlappingChoices
        case answerIndexOutOfRange
        /// The right answer is neither in the homework text nor a bank answer.
        case notGrounded
        /// The stem names something (a capitalised word) found neither in
        /// the homework text nor in the bank answers: a likely made-up fact
        /// (« Qui a écrit Germinal ? » on a homework about Victor Hugo).
        case ungroundedStem
        /// A wrong answer is also written in the homework text: it may be
        /// right too.
        case ambiguousDistractor
        /// A URL, a domain or a Markdown link (homework often carries links).
        case link
        /// The right answer is only the due date or the subject label: a
        /// question about logistics, not about what to learn.
        case trivial
        /// Vouvoiement / parent address in a child-mode question.
        case parentTone
        case sensitiveContent
        /// Valid, but over the per-quiz cap.
        case overCap
    }

    struct Result: Sendable, Equatable {
        var accepted: [QuizCandidate] = []
        var rejections: [Rejection] = []
    }

    static let maxQuestionLength = 300
    static let maxChoiceLength = 120
    static let maxExplanationLength = 400

    static func validate(_ candidates: [QuizCandidate], request: QuizGenerationRequest,
                         maxCount: Int = QuizGenerator.maxGeneratedPerQuiz) -> Result {
        var result = Result()
        var seenKeys = Set<String>()
        for candidate in candidates {
            if let reason = rejection(for: candidate, request: request) {
                result.rejections.append(reason)
                continue
            }
            let trimmed = trim(candidate)
            guard seenKeys.insert(QuizKey.make(question: trimmed.question, choices: trimmed.choices)).inserted
            else { continue }   // same question twice: silently keep one
            if result.accepted.count >= max(0, min(maxCount, QuizGenerator.maxGeneratedPerQuiz)) {
                result.rejections.append(.overCap)
                continue
            }
            result.accepted.append(trimmed)
        }
        return result
    }

    /// First reason to drop `candidate`, nil when it is acceptable.
    static func rejection(for candidate: QuizCandidate, request: QuizGenerationRequest) -> Rejection? {
        let c = trim(candidate)
        if c.question.isEmpty { return .emptyQuestion }
        if !c.question.hasSuffix("?") { return .notAQuestion }
        if c.question.count > maxQuestionLength || c.explanation.count > maxExplanationLength
            || c.choices.contains(where: { $0.count > maxChoiceLength }) { return .tooLong }
        if c.choices.count != 4 { return .choiceCount }
        let normalized = c.choices.map(QuizKey.normalizeName)
        if c.choices.contains(where: \.isEmpty) || normalized.contains(where: \.isEmpty) { return .emptyChoice }
        if Set(normalized).count != normalized.count { return .duplicateChoices }
        if hasOverlap(normalized) { return .overlappingChoices }
        if !c.choices.indices.contains(c.answerIndex) { return .answerIndexOutOfRange }
        let allText = ([c.question, c.explanation] + c.choices).joined(separator: " ")
        if containsSensitiveContent(allText) { return .sensitiveContent }
        if containsLink(allText) { return .link }
        if usesParentTone(c.question) || usesParentTone(c.explanation) { return .parentTone }
        let answer = c.choices[c.answerIndex]
        if isTrivial(answer: answer, request: request) { return .trivial }
        if !isGrounded(answer: answer, request: request) { return .notGrounded }
        if !isStemGrounded(c.question, request: request) { return .ungroundedStem }
        let wrong = c.choices.enumerated().filter { $0.offset != c.answerIndex }.map(\.element)
        if wrong.contains(where: { appearsInHomework($0, request: request) }) { return .ambiguousDistractor }
        return nil
    }

    /// The right answer appears in the homework text as whole words (accent
    /// / case insensitive, so « Rome » does not match « Roméo »), or equals
    /// a bank answer of the same level / subject / theme. Checked against
    /// the homework description only, never the « Matière : … / Pour le … »
    /// scaffolding of `sourceText`.
    static func isGrounded(answer: String, request: QuizGenerationRequest) -> Bool {
        let folded = QuizKey.normalizeName(answer)
        guard !folded.isEmpty else { return false }
        if request.bankAnswers.contains(where: { QuizKey.normalizeName($0) == folded }) { return true }
        return appearsInHomework(answer, request: request)
    }

    /// `text`, normalized, is a whole-word run of the normalized homework text.
    static func appearsInHomework(_ text: String, request: QuizGenerationRequest) -> Bool {
        let folded = QuizKey.normalizeName(text)
        guard !folded.isEmpty else { return false }
        return containsWords(QuizKey.normalizeName(request.homeworkText), folded)
    }

    private static func containsWords(_ normalizedText: String, _ normalizedWords: String) -> Bool {
        (" " + normalizedText + " ").contains(" " + normalizedWords + " ")
    }

    /// Sentence-opening words a question may start with in French. Only
    /// these are exempt from the capitalisation check as the first word: an
    /// unknown first word (« Germinal a été écrit par… ») is a proper noun
    /// and must be grounded like any other.
    static let questionOpeners: Set<String> = [
        "quel", "quelle", "quels", "quelles", "qui", "que", "quoi", "ou", "comment", "combien",
        "pourquoi", "quand", "lequel", "laquelle", "lesquels", "lesquelles", "dans", "selon",
        "en", "a", "au", "aux", "le", "la", "les", "un", "une", "des", "de", "du", "est",
        "parmi", "pour", "avec", "sur", "d", "l", "qu", "c", "ce", "cette", "ces", "on", "tu",
    ]

    /// Every capitalised word of the stem (a name, a title, a place: what a
    /// made-up fact hangs on) is in the homework text or in a bank answer.
    /// The first word is exempt only when it is a known question opener.
    /// Words under 3 letters are ignored (« L' », « A »).
    static func isStemGrounded(_ question: String, request: QuizGenerationRequest) -> Bool {
        let homework = QuizKey.normalizeName(request.homeworkText)
        let bank = request.bankAnswers.map(QuizKey.normalizeName)
        var words = question.split(whereSeparator: { !$0.isLetter && !$0.isNumber })[...]
        if let first = words.first, questionOpeners.contains(QuizKey.normalizeName(String(first))) {
            words = words.dropFirst()
        }
        for word in words where word.count >= 3 && (word.first?.isUppercase ?? false) {
            let folded = QuizKey.normalizeName(String(word))
            guard !folded.isEmpty else { continue }
            if containsWords(homework, folded) { continue }
            if bank.contains(where: { containsWords($0, folded) }) { continue }
            return false
        }
        return true
    }

    /// True when a normalized choice contains another one as whole words.
    static func hasOverlap(_ normalizedChoices: [String]) -> Bool {
        for (i, a) in normalizedChoices.enumerated() {
            for (j, b) in normalizedChoices.enumerated() where i != j {
                if (" " + a + " ").contains(" " + b + " ") { return true }
            }
        }
        return false
    }

    /// An answer that is just (part of) the due date or the subject label.
    static func isTrivial(answer: String, request: QuizGenerationRequest) -> Bool {
        let folded = QuizKey.normalizeName(answer)
        guard !folded.isEmpty else { return false }
        // The whole label, each of its words (« Géographie » in
        // HISTOIRE-GEOGRAPHIE) and its canonical curriculum names.
        let names = [request.homeworkSubject, request.subject]
            + SubjectAlias.canonicalNames(for: request.homeworkSubject)
            + SubjectAlias.canonicalNames(for: request.subject)
        let words = names.flatMap { label in
            label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let labels = names + words
        if labels.contains(where: { QuizKey.normalizeName($0) == folded }) { return true }
        return CurriculumService.textMatches(QuizKey.normalizeName(request.dueDateText), keyword: folded)
    }

    /// Child mode addresses the child: a stem or explanation that says
    /// « vous / votre / vos » (or talks about « votre enfant ») is parent
    /// tone. Over-rejection only costs a bank question.
    static func usesParentTone(_ text: String) -> Bool {
        let words = Set(SubjectAlias.tokens(text))
        return !words.isDisjoint(with: ["vous", "votre", "vos"])
    }

    /// Belt and braces over Apple's guardrails: a short folded word list
    /// (prefix match, so plurals and conjugations are caught), plus anything
    /// that looks like contact data copied from the homework (an e-mail
    /// address or a phone number), which has no place in a quiz.
    static func containsSensitiveContent(_ text: String) -> Bool {
        if text.contains("@") { return true }
        let digits = text.filter(\.isNumber)
        if digits.count >= 10,
           text.range(of: #"(\+33|0)\s*[1-9](?:[\s.\-]*\d{2}){4}"#, options: .regularExpression) != nil {
            return true
        }
        let tokens = SubjectAlias.tokens(text)
        return tokens.contains { token in sensitivePrefixes.contains { token.hasPrefix($0) } }
    }

    /// A link of any shape: scheme, « www. », a Markdown / autolink, or a
    /// bare domain. Generated text is rendered as plain text anyway; this
    /// keeps third-party addresses out of the child's quiz altogether.
    static func containsLink(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b[a-z][a-z0-9+.\-]*://"#,
            #"(?i)\bwww\."#,
            #"\]\s*\("#,
            #"<[^>\s]+:[^>\s]*>"#,
            #"(?i)\b[a-z0-9\-]+(\.[a-z0-9\-]+)*\.(fr|com|org|net|io|eu|edu|gouv|info|be|ch|ca|me|tv|ly|co|app|dev)\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static let sensitivePrefixes: [String] = [
        "suicid", "automutil", "scarifi", "porno", "drogu", "cannabis", "cocain", "putain", "merde",
        "connard", "connass", "salope", "encule", "pute", "batard", "nique",
    ]

    /// Key of the generated question of a homework: one stable key per
    /// homework, whatever the model wrote (temperature 0.4 rewrites it on
    /// every « Un autre quiz »), so `RewardPolicy.isReplay` and the XP guard
    /// still see a replay of the same bank items + the same homework.
    static func questionKey(homeworkKey: String) -> String {
        "generated#" + homeworkKey
    }

    /// The playable question for an accepted candidate.
    /// - The explanation shown is the homework sentence that holds the
    ///   answer, never the model's own text (unchecked against the source).
    /// - `notionKey` is nil: unreviewed output never moves `NotionMastery`.
    static func question(from candidate: QuizCandidate, request: QuizGenerationRequest) -> QuizQuestion {
        let c = trim(candidate)
        let key = questionKey(homeworkKey: request.homeworkKey)
        let explanation = homeworkQuote(containing: c.choices[c.answerIndex], request: request)
        return QuizQuestion(id: QuizKey.deterministicID(for: key), questionKey: key,
                            question: c.question, choices: c.choices, answerIndex: c.answerIndex,
                            explanation: explanation, subject: request.subject, theme: request.theme,
                            notionKey: nil, difficulty: 1, isGenerated: true)
    }

    /// « D'après ton devoir : « … » » with the first homework sentence that
    /// contains `answer` (whole words), nil when none does (bank-grounded
    /// answer) or when that sentence carries a link or contact data.
    static func homeworkQuote(containing answer: String, request: QuizGenerationRequest) -> String? {
        let folded = QuizKey.normalizeName(answer)
        guard !folded.isEmpty else { return nil }
        guard let sentence = sentences(request.homeworkText).first(where: {
            containsWords(QuizKey.normalizeName($0), folded)
        }) else { return nil }
        guard sentence.count <= maxExplanationLength, !containsLink(sentence),
              !containsSensitiveContent(sentence) else { return nil }
        return "D'après ton devoir : « \(sentence) »"
    }

    /// Sentences of `text`: cut at line breaks and at « . ! ? » followed by a space.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if ch.isNewline {
                result.append(current)
                current = ""
                continue
            }
            current.append(ch)
            if ".!?".contains(ch), i + 1 < chars.count, chars[i + 1].isWhitespace {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func trim(_ c: QuizCandidate) -> QuizCandidate {
        let ws = CharacterSet.whitespacesAndNewlines
        return QuizCandidate(question: c.question.trimmingCharacters(in: ws),
                             choices: c.choices.map { $0.trimmingCharacters(in: ws) },
                             answerIndex: c.answerIndex,
                             explanation: c.explanation.trimmingCharacters(in: ws))
    }
}
