import Foundation

/// Pure builder for the strength-insight label displayed on the
/// Insights screen — e.g. `"Point fort en progression (17.1/20) · moy. classe 13.6"`.
///
/// Extracted from `InsightEngine.analyze` so the "with vs without
/// class average" and "improving vs stable" branches are unit-tested
/// without needing to spin up a SwiftData container.
enum InsightLabelBuilder {

    /// - Parameters:
    ///   - average: child's normalized /20 average for the subject
    ///   - improving: whether the detected trend points upward
    ///   - classAverages: the `classAverage` values pulled from the
    ///     grades of that subject (already compacted — nil values
    ///     stripped by the caller). Empty means "no class reference".
    static func strengthLabel(
        average: Double,
        improving: Bool,
        classAverages: [Double]
    ) -> String {
        var label = improving
            ? "Point fort en progression (\(String(format: "%.1f", average))/20)"
            : "Point fort (\(String(format: "%.1f", average))/20)"
        if !classAverages.isEmpty {
            let classAvg = classAverages.reduce(0, +) / Double(classAverages.count)
            label += " · moy. classe \(String(format: "%.1f", classAvg))"
        }
        return label
    }
}
