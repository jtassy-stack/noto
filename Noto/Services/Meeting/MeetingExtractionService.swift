import Foundation

/// Turns a raw meeting transcript into `[ExtractedItem]` — always
/// non-confirmed, always reviewed by a parent before anything here can
/// reach `BriefingEngine` (see `ExtractedItem.confirmedByUser`).
///
/// iOS 26+: Apple FoundationModels guided generation first
/// (`OnDeviceMeetingExtractor`, on-device system model), rule-based pass
/// otherwise. No network call either way, so there is no privacy difference
/// between the two paths, only a quality one.
enum MeetingExtractionService {
    static func extract(transcript: String, childNames: [String]) async -> [ExtractedItem] {
        if #available(iOS 26.0, *), let items = await foundationModelExtraction(transcript: transcript, childNames: childNames) {
            return items
        }
        return ruleBasedExtraction(transcript: transcript, childNames: childNames)
    }

    // MARK: - FoundationModels (iOS 26+)

    /// The on-device context window is 4096 tokens on iOS 26: a longer
    /// transcript goes straight to the rule-based pass.
    static let maxModelTranscriptCharacters = 6000
    private static let modelTimeout: Duration = .seconds(20)
    /// Above the rule-based 0.3, still well short of "trust as is".
    static let modelConfidence = 0.5

    @available(iOS 26.0, *)
    private static func foundationModelExtraction(transcript: String, childNames: [String]) async -> [ExtractedItem]? {
        #if canImport(FoundationModels)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxModelTranscriptCharacters else { return nil }
        let today = isoDay.string(from: .now)
        guard let drafts = await AsyncTimeout.run(modelTimeout, operation: {
            await OnDeviceMeetingExtractor.extract(transcript: text, childNames: childNames, today: today)
        }) else { return nil }
        let items = parseFacts(drafts, childNames: childNames)
        // Nothing usable from the model: let the rule-based pass try.
        return items.isEmpty ? nil : items
        #else
        return nil
        #endif
    }

    /// Validates the model's facts (pure, testable without the model): known
    /// kind, non-empty title (cut to 80), child name kept only when it is one
    /// of the family's, date parsed as `yyyy-MM-dd` and kept for agenda only.
    static func parseFacts(_ drafts: [MeetingFactDraft], childNames: [String]) -> [ExtractedItem] {
        let ws = CharacterSet.whitespacesAndNewlines
        let formatter = isoDay
        return drafts.compactMap { draft in
            guard let kind = ExtractedItemKind(rawValue: draft.kind.trimmingCharacters(in: ws).lowercased()) else {
                return nil
            }
            let title = draft.title.trimmingCharacters(in: ws)
            guard !title.isEmpty else { return nil }
            let detail = draft.detail.trimmingCharacters(in: ws)
            let name = draft.childName.trimmingCharacters(in: ws)
            let child = childNames.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            let date = kind == .agenda ? formatter.date(from: draft.dueDate.trimmingCharacters(in: ws)) : nil
            return ExtractedItem(kind: kind, childName: child, title: String(title.prefix(80)),
                                 detail: detail.isEmpty ? nil : detail, dueDate: date,
                                 confidence: modelConfidence)
        }
    }

    /// A fresh formatter per call: `DateFormatter` is not `Sendable`.
    private static var isoDay: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }

    // MARK: - Rule-based fallback (all iOS versions)

    /// Deliberately low-confidence: this is a coarse pass meant to seed
    /// the review screen, not to be trusted as-is. `confirmedByUser`
    /// keeps any of it from acting on its own regardless of confidence.
    private static func ruleBasedExtraction(transcript: String, childNames: [String]) -> [ExtractedItem] {
        var items: [ExtractedItem] = []
        let sentences = transcript
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

        let policyKeywords = ["obligatoire", "interdit", "impératif", "impérativement", "ne peut pas", "n'a pas le droit"]
        let contactPattern = try? NSRegularExpression(pattern: #"\b(M\.|Mme|Madame|Monsieur)\s+[A-ZÀ-Ý][a-zà-ÿ'-]+"#)

        for sentence in sentences {
            let matchedChild = childNames.first { sentence.localizedCaseInsensitiveContains($0) }
            let range = NSRange(sentence.startIndex..., in: sentence)

            // Agenda: a sentence containing a detectable date.
            if let detector, let match = detector.firstMatch(in: sentence, range: range),
               let date = match.date {
                items.append(ExtractedItem(
                    kind: .agenda,
                    childName: matchedChild,
                    title: String(sentence.prefix(80)),
                    detail: sentence.count > 80 ? sentence : nil,
                    dueDate: date,
                    confidence: 0.3
                ))
                continue
            }

            // Contact: "M./Mme <Nom>" mentioned in the sentence.
            if let contactPattern, let match = contactPattern.firstMatch(in: sentence, range: range),
               let matchRange = Range(match.range, in: sentence) {
                items.append(ExtractedItem(
                    kind: .contact,
                    childName: matchedChild,
                    title: String(sentence[matchRange]),
                    detail: sentence,
                    confidence: 0.3
                ))
                continue
            }

            // Policy: a rule/constraint keyword.
            if policyKeywords.contains(where: { sentence.localizedCaseInsensitiveContains($0) }) {
                items.append(ExtractedItem(
                    kind: .policy,
                    childName: matchedChild,
                    title: String(sentence.prefix(80)),
                    detail: sentence.count > 80 ? sentence : nil,
                    confidence: 0.3
                ))
            }
        }

        return items
    }
}

/// One fact as the on-device model returned it (plain strings, no
/// FoundationModels type), before `MeetingExtractionService.parseFacts`.
struct MeetingFactDraft: Sendable, Equatable {
    let kind: String
    let childName: String
    let title: String
    let detail: String
    let dueDate: String
}
