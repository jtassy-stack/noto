import Foundation

/// On-device analysis of grade trends and difficulty detection.
/// Pure computation — no network, no data leaves the device.
enum TrendAnalyzer {

    /// Analyze grade trend for a subject over time.
    /// Returns slope of linear regression (positive = improving, negative = declining).
    static func gradeTrend(grades: [GradePoint]) -> TrendResult? {
        guard grades.count >= 3 else { return nil }

        let sorted = grades.sorted { $0.date < $1.date }

        // Linear regression: y = mx + b
        // x = days since first grade, y = normalized value (/20)
        let startDate = sorted.first!.date
        let points: [(x: Double, y: Double)] = sorted.map { grade in
            let days = grade.date.timeIntervalSince(startDate) / 86400
            return (x: days, y: grade.normalizedValue)
        }

        let n = Double(points.count)
        let sumX = points.reduce(0.0) { $0 + $1.x }
        let sumY = points.reduce(0.0) { $0 + $1.y }
        let sumXY = points.reduce(0.0) { $0 + $1.x * $1.y }
        let sumX2 = points.reduce(0.0) { $0 + $1.x * $1.x }

        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n

        // R² for confidence
        let yMean = sumY / n
        let ssRes = points.reduce(0.0) { sum, p in
            let predicted = slope * p.x + intercept
            return sum + (p.y - predicted) * (p.y - predicted)
        }
        let ssTot = points.reduce(0.0) { sum, p in
            sum + (p.y - yMean) * (p.y - yMean)
        }
        let rSquared = ssTot > 0 ? 1 - (ssRes / ssTot) : 0

        // Current and recent average
        let recentCount = min(4, sorted.count)
        let recentAvg = sorted.suffix(recentCount).reduce(0.0) { $0 + $1.normalizedValue } / Double(recentCount)
        let overallAvg = sumY / n

        return TrendResult(
            slope: slope,
            rSquared: rSquared,
            recentAverage: recentAvg,
            overallAverage: overallAvg,
            gradeCount: Int(n),
            direction: TrendDirection(slope: slope, confidence: rSquared)
        )
    }

    /// Detect subjects where the child is struggling.
    static func detectDifficulties(gradesBySubject: [String: [GradePoint]]) -> [SubjectDifficulty] {
        var difficulties: [SubjectDifficulty] = []

        for (subject, grades) in gradesBySubject {
            guard let trend = gradeTrend(grades: grades) else { continue }

            let severity: DifficultySeverity
            if trend.recentAverage < 8 && trend.direction == .declining {
                severity = .high
            } else if trend.recentAverage < 10 || (trend.direction == .declining && trend.rSquared > 0.5) {
                severity = .medium
            } else if trend.direction == .declining && trend.recentAverage < 12 {
                severity = .low
            } else {
                continue // Not a difficulty
            }

            difficulties.append(SubjectDifficulty(
                subject: subject,
                severity: severity,
                trend: trend
            ))
        }

        return difficulties.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }

    /// Detect subjects where the child excels.
    static func detectStrengths(gradesBySubject: [String: [GradePoint]]) -> [SubjectStrength] {
        var strengths: [SubjectStrength] = []

        for (subject, grades) in gradesBySubject {
            guard let trend = gradeTrend(grades: grades) else { continue }

            if trend.recentAverage >= 14 && trend.direction != .declining {
                strengths.append(SubjectStrength(
                    subject: subject,
                    average: trend.recentAverage,
                    improving: trend.direction == .improving
                ))
            }
        }

        return strengths.sorted { $0.average > $1.average }
    }
}

// MARK: - Types

struct GradePoint {
    let date: Date
    let normalizedValue: Double // /20
}

struct TrendResult {
    let slope: Double           // Points per day
    let rSquared: Double        // 0-1, confidence
    let recentAverage: Double   // Last 4 grades avg
    let overallAverage: Double
    let gradeCount: Int
    let direction: TrendDirection

    /// Weekly change in points
    var weeklyChange: Double { slope * 7 }

    /// Human-readable description in French
    var description: String {
        let change = abs(weeklyChange)
        let formatted = String(format: "%.1f", change)
        switch direction {
        case .improving:
            return "En progression (+\(formatted) pts/semaine)"
        case .declining:
            return "En baisse (-\(formatted) pts/semaine)"
        case .stable:
            return "Stable (moyenne \(String(format: "%.1f", recentAverage))/20)"
        }
    }
}

enum TrendDirection: Sendable {
    case improving
    case declining
    case stable

    init(slope: Double, confidence: Double) {
        let significantSlope = 0.02 // ~0.14 pts/week threshold
        if confidence < 0.3 || abs(slope) < significantSlope {
            self = .stable
        } else if slope > 0 {
            self = .improving
        } else {
            self = .declining
        }
    }
}

struct SubjectDifficulty {
    let subject: String
    let severity: DifficultySeverity
    let trend: TrendResult
}

enum DifficultySeverity: Int {
    case low = 1
    case medium = 2
    case high = 3
}

struct SubjectStrength {
    let subject: String
    let average: Double
    let improving: Bool
}
