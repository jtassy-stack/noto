import Testing
import Foundation
@testable import Noto

/// Coverage for the strength-insight label. The class-average suffix
/// is the only part of the Insights screen that gives parents a frame
/// of reference, so pinning the arithmetic and the "no class average"
/// fallback protects against silent regressions in InsightEngine.
@Suite("InsightLabelBuilder")
struct InsightLabelBuilderTests {

    @Test("Improving, no class average")
    func improvingNoClass() {
        let label = InsightLabelBuilder.strengthLabel(
            average: 17.1,
            improving: true,
            classAverages: []
        )
        #expect(label == "Point fort en progression (17.1/20)")
    }

    @Test("Stable, no class average")
    func stableNoClass() {
        let label = InsightLabelBuilder.strengthLabel(
            average: 16.0,
            improving: false,
            classAverages: []
        )
        #expect(label == "Point fort (16.0/20)")
    }

    @Test("Improving with class average → appended suffix")
    func improvingWithClass() {
        let label = InsightLabelBuilder.strengthLabel(
            average: 17.1,
            improving: true,
            classAverages: [13.6]
        )
        #expect(label == "Point fort en progression (17.1/20) · moy. classe 13.6")
    }

    @Test("Stable with class average")
    func stableWithClass() {
        let label = InsightLabelBuilder.strengthLabel(
            average: 15.5,
            improving: false,
            classAverages: [12.0]
        )
        #expect(label == "Point fort (15.5/20) · moy. classe 12.0")
    }

    @Test("Multiple class averages → arithmetic mean")
    func multipleClassAverages() {
        // (12 + 14 + 16) / 3 = 14.0
        let label = InsightLabelBuilder.strengthLabel(
            average: 17.0,
            improving: false,
            classAverages: [12.0, 14.0, 16.0]
        )
        #expect(label == "Point fort (17.0/20) · moy. classe 14.0")
    }

    @Test("Rounding: %.1f truncates to one decimal, non-integer mean")
    func rounding() {
        // (13.3 + 13.5) / 2 = 13.4 exactly → "13.4"
        let label = InsightLabelBuilder.strengthLabel(
            average: 17.2,
            improving: true,
            classAverages: [13.3, 13.5]
        )
        // Locale-safe: `String(format:)` uses the C locale ('.').
        #expect(label == "Point fort en progression (17.2/20) · moy. classe 13.4")
    }
}
