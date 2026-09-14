import Foundation

/// Turns a raw meeting transcript into `[ExtractedItem]` — always
/// non-confirmed, always reviewed by a parent before anything here can
/// reach `BriefingEngine` (see `ExtractedItem.confirmedByUser`).
///
/// iOS 26+: intended to use Apple FoundationModels guided generation once
/// the SDK is available in Xcode (same availability gate and same "not
/// wired yet" state as `TextSummarizer.foundationModelWithTools`) — no
/// network call either way, so there is no privacy difference between the
/// two paths, only a quality one.
enum MeetingExtractionService {
    static func extract(transcript: String, childNames: [String]) async -> [ExtractedItem] {
        if #available(iOS 26.0, *), let items = await foundationModelExtraction(transcript: transcript, childNames: childNames) {
            return items
        }
        return ruleBasedExtraction(transcript: transcript, childNames: childNames)
    }

    // MARK: - FoundationModels (iOS 26+)

    @available(iOS 26.0, *)
    private static func foundationModelExtraction(transcript: String, childNames: [String]) async -> [ExtractedItem]? {
        // TODO: Wire to FoundationModels guided generation when the SDK is
        // available in Xcode — same gap as TextSummarizer.swift:48. A
        // @Generable schema mirroring ExtractedItem's fields, given the
        // transcript + childNames, would replace ruleBasedExtraction below
        // as the primary path. Until then this always falls through.
        return nil
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
