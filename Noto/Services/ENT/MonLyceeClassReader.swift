import Foundation

/// Finds a child's class ("2NDE2", "6EME2") in a MonLycée `/logbook`
/// individual, so a MonLycée child gets its level without waiting for a
/// Pronote session (which often fails for parent accounts).
///
/// The logbook schema is not documented, so the reader walks the individual
/// and only looks at string values under class-like keys (`className`,
/// `classe`, `division`, `classes`…). Homework and grade subtrees are skipped:
/// their free text ("3e trimestre") must never become a class. A value only
/// counts when `GradeInference.grade(from:)` recognises a 6e → Tle level.
enum MonLyceeClassReader {

    /// Subtrees that hold school data, never the child's class.
    private static let skippedKeys: Set<String> = ["work", "notation", "notebook", "grades", "absences", "messages"]

    /// Class label of `individual`, or nil when none is recognised.
    static func className(in individual: [String: Any]) -> String? {
        search(individual, depth: 0, underClassKey: false)
    }

    private static func isClassKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.contains("class") || k.contains("division") || k == "groupname"
    }

    private static func search(_ value: Any, depth: Int, underClassKey: Bool) -> String? {
        guard depth < 6 else { return nil }
        switch value {
        case let string as String:
            guard underClassKey else { return nil }
            let label = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return GradeInference.grade(from: label).isEmpty ? nil : label
        case let dict as [String: Any]:
            // Class-like keys first, so a direct `className` wins over a nested one.
            let sorted = dict.keys.sorted()
            let keys = sorted.filter(isClassKey) + sorted.filter { !isClassKey($0) }
            for key in keys where !skippedKeys.contains(key.lowercased()) {
                let classKey = underClassKey || isClassKey(key)
                if let found = search(dict[key] as Any, depth: depth + 1, underClassKey: classKey) { return found }
            }
            return nil
        case let array as [Any]:
            for item in array {
                if let found = search(item, depth: depth + 1, underClassKey: underClassKey) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}
