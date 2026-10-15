import CryptoKit
import Foundation

/// Swift port of celyn's quiz identity (`src/lib/koi/core.ts` `questionKey`
/// + `src/lib/normalize.ts` `normalizeName`). Both sides must produce the
/// same string: celyn re-dates rows and bank items are regenerated, so this
/// key is the only stable identity of a question (replay detection, dedup).
/// Pinned by golden vectors generated from celyn's code (`QuizKeyTests`).
enum QuizKey {
    /// `normalizeName(question)` cut to 240, `#`, the sorted normalised
    /// choices joined by `|`, the whole cut to 500.
    static func make(question: String, choices: [String]) -> String {
        let c = choices.map(normalizeName).sorted().joined(separator: "|")
        let key = String(normalizeName(question).prefix(240)) + "#" + c
        return String(key.prefix(500))
    }

    /// celyn `normalizeName`, step by step: NFD → strip U+0300–U+036F →
    /// lowercase → strip one leading article (`le `, `la `, `les `, `l'`,
    /// `l’`, `the `) → every char outside `[a-z0-9]` becomes a space →
    /// collapse whitespace → trim. The output is ASCII, so `prefix` on
    /// Characters equals JS `slice` on UTF-16 units.
    static func normalizeName(_ name: String) -> String {
        let decomposed = name.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }
        var s = String(String.UnicodeScalarView(decomposed)).lowercased()
        for article in ["le ", "la ", "les ", "l'", "l\u{2019}", "the "] where s.hasPrefix(article) {
            s.removeFirst(article.count)
            break
        }
        let mapped = s.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39: return Character(scalar)
            default: return " "
            }
        }
        return String(mapped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Namespace of nōto's deterministic quiz ids. Fixed forever: changing it
    /// re-identifies every bank / homework item. Android must use the same value.
    static let namespace = UUID(uuidString: "6E6F746F-2D71-5A69-8B00-6E6F746F7175")!

    /// RFC 4122 version-5 UUID of `questionKey` in `namespace`. Used as the id
    /// of bank / homework items, which have no celyn uuid.
    static func deterministicID(for questionKey: String) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(questionKey.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
