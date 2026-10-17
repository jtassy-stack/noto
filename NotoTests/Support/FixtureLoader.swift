import Foundation

/// Loads a JSON fixture from `NotoTests/Fixtures` (test bundle resource),
/// falling back to the source tree. Fixtures hold made-up data only.
enum FixtureLoader {
    private final class Token {}

    static func data(_ name: String, filePath: String = #filePath) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle(for: Token.self).url(forResource: base, withExtension: ext.isEmpty ? "json" : ext) {
            return try Data(contentsOf: url)
        }
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.lastPathComponent != "NotoTests" && dir.path != "/" {
            dir.deleteLastPathComponent()
        }
        return try Data(contentsOf: dir.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }
}
