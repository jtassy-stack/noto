#if canImport(FoundationModels)
import Foundation
import FoundationModels
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "TextSummarizer")

/// FoundationModels step of `TextSummarizer.summarize` (fallback chain
/// step 1, CLAUDE.md): the on-device system model turns the pre-built
/// briefing items into a few sentences of prose for the parent. Nil when the
/// model is not usable or the call fails; the template text is used then.
@available(iOS 26.0, *)
enum OnDeviceBriefingModel {
    static let instructions = """
    Tu es l'assistant de nōto, une application pour les parents d'élèves.
    Tu t'adresses au parent, pas à l'élève : vouvoie le parent et parle de l'enfant à la troisième personne
    (« Votre enfant a 5 cours aujourd'hui », jamais « Tu as 5 cours »).
    Écris en français, de manière concise et chaleureuse, en 2 à 4 phrases de prose, sans liste à puces.
    Commence par ce qui est urgent. N'utilise que les éléments fournis : n'invente aucune note,
    aucun devoir, aucune date ni aucun nom.
    """

    static func respond(prompt: String) async -> String? {
        let model = SystemLanguageModel.default
        guard model.availability == .available,
              model.supportsLocale(Locale(identifier: "fr_FR")) else { return nil }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 300)
            )
            return response.content
        } catch {
            logger.info("On-device briefing failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }
}
#endif
