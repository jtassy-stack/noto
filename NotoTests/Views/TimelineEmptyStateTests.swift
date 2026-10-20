import Testing
import Foundation
@testable import Noto

/// Accueil « Prochaines 48h »: an empty window (holidays, weekend) still says
/// when the next class is.
@Suite("TimelineEmptyState")
struct TimelineEmptyStateTests {
    private let windowEnd = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func picksFirstNonCancelledLessonAfterTheWindow() {
        let lessons: [(start: Date, cancelled: Bool)] = [
            (windowEnd.addingTimeInterval(-3600), false),
            (windowEnd.addingTimeInterval(7200), true),
            (windowEnd.addingTimeInterval(86_400), false),
            (windowEnd.addingTimeInterval(10_800), false),
        ]
        #expect(TimelineView.nextLessonStart(after: windowEnd, lessons: lessons)
                == windowEnd.addingTimeInterval(10_800))
    }

    @Test func noLessonMeansNoDate() {
        #expect(TimelineView.nextLessonStart(after: windowEnd, lessons: []) == nil)
        #expect(TimelineView.emptyText(nextLesson: nil) == "Aucun cours ni devoir d'ici 48 h.")
    }

    @Test func namesTheNextClassDay() {
        #expect(TimelineView.emptyText(nextLesson: windowEnd).hasPrefix("Aucun cours d'ici 48 h. Prochain cours : "))
    }
}
