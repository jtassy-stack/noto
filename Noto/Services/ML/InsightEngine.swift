import Foundation
import SwiftData

/// Generates Insight records from grade analysis.
/// Runs on-device after each sync, writes to SwiftData.
@MainActor
final class InsightEngine {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Analyze a child's grades and generate/update insights.
    func analyze(child: Child) {
        // Group grades by subject
        let gradesBySubject = Dictionary(grouping: child.grades) { $0.subject }

        let gradePoints: [String: [GradePoint]] = gradesBySubject.mapValues { grades in
            grades.map { GradePoint(date: $0.date, normalizedValue: $0.normalizedValue) }
        }

        // Clear stale insights for this child
        for insight in child.insights {
            modelContext.delete(insight)
        }

        // Detect difficulties
        let difficulties = TrendAnalyzer.detectDifficulties(gradesBySubject: gradePoints)
        for diff in difficulties {
            let insight = Insight(
                type: .difficulty,
                subject: diff.subject,
                value: diff.trend.description,
                confidence: diff.trend.rSquared
            )
            insight.child = child
            modelContext.insert(insight)
        }

        // Detect strengths
        let strengths = TrendAnalyzer.detectStrengths(gradesBySubject: gradePoints)
        for str in strengths {
            var label = str.improving
                ? "Point fort en progression (\(String(format: "%.1f", str.average))/20)"
                : "Point fort (\(String(format: "%.1f", str.average))/20)"
            // Append class average so the card reads "17.1/20 · moy. classe 13.6" —
            // a bare grade has no frame of reference.
            let classAverages = (gradesBySubject[str.subject] ?? []).compactMap(\.classAverage)
            if !classAverages.isEmpty {
                let classAvg = classAverages.reduce(0, +) / Double(classAverages.count)
                label += " · moy. classe \(String(format: "%.1f", classAvg))"
            }
            let insight = Insight(
                type: .strength,
                subject: str.subject,
                value: label,
                confidence: 0.8
            )
            insight.child = child
            modelContext.insert(insight)
        }

        // Generate trend insights for all subjects with enough data
        for (subject, points) in gradePoints {
            guard let trend = TrendAnalyzer.gradeTrend(grades: points) else { continue }
            // Only create trend insight if not already covered by difficulty/strength
            let alreadyCovered = difficulties.contains { $0.subject == subject }
                || strengths.contains { $0.subject == subject }
            guard !alreadyCovered else { continue }

            if trend.direction != .stable {
                let insight = Insight(
                    type: .trend,
                    subject: subject,
                    value: trend.description,
                    confidence: trend.rSquared
                )
                insight.child = child
                modelContext.insert(insight)
            }
        }

        try? modelContext.save()
    }

    /// Build difficulty contexts for CurriculumMatcher.
    func difficultyContexts(for child: Child) -> [DifficultyContext] {
        child.insights
            .filter { $0.type == .difficulty }
            .map { DifficultyContext(subject: $0.subject, trend: -1) }
    }

    /// Build chapter contexts from recent schedule and homework.
    func chapterContexts(for child: Child) -> [ChapterContext] {
        var contexts: [ChapterContext] = []

        // From schedule (last 7 days + next 7 days)
        let now = Date.now
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let weekAhead = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        for entry in child.schedule where entry.start >= weekAgo && entry.start <= weekAhead {
            if let chapter = entry.chapter {
                contexts.append(ChapterContext(subject: entry.subject, text: chapter))
            }
        }

        // From homework (upcoming)
        for hw in child.homework where hw.dueDate >= now && hw.dueDate <= weekAhead {
            contexts.append(ChapterContext(subject: hw.subject, text: hw.descriptionText))
        }

        return contexts
    }
}
