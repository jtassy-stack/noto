import ExpoModulesCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public class OnDeviceMlModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OnDeviceMl")

    // Check if on-device ML is available (iOS 26+ with Apple Intelligence)
    Function("isAvailable") { () -> Bool in
      #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        return Self.checkAvailability()
      }
      #endif
      return false
    }

    // Generate a summary from structured context
    AsyncFunction("generateSummary") { (context: String, instructions: String) -> String in
      #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        return try await Self.generate(context: context, instructions: instructions)
      }
      #endif
      throw MLError.notAvailable
    }
  }

  // MARK: - FoundationModels implementation

  #if canImport(FoundationModels)
  @available(iOS 26.0, *)
  private static func checkAvailability() -> Bool {
    let availability = SystemLanguageModel.default.availability
    switch availability {
    case .available:
      return true
    default:
      return false
    }
  }

  @available(iOS 26.0, *)
  private static func generate(context: String, instructions: String) async throws -> String {
    let availability = SystemLanguageModel.default.availability
    guard case .available = availability else {
      throw MLError.notAvailable
    }

    let session = LanguageModelSession(instructions: instructions)
    let response = try await session.respond(to: context)
    return response.content
  }
  #endif

  enum MLError: Error, LocalizedError {
    case notAvailable
    case generationFailed(String)

    var errorDescription: String? {
      switch self {
      case .notAvailable:
        return "Apple Intelligence n'est pas disponible sur cet appareil"
      case .generationFailed(let reason):
        return "Échec de la génération : \(reason)"
      }
    }
  }
}
