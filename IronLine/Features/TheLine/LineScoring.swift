import Foundation

struct PerformanceLine: Equatable {
    let weight: Double
    let reps: Int

    var estimatedOneRepMax: Double {
        LineScoring.estimatedOneRepMax(weight: weight, reps: reps)
    }
}

struct LineResult: Equatable {
    let actualE1RM: Double
    let targetE1RM: Double
    let scorePercent: Double

    var beatLine: Bool { scorePercent > 0 }
}

enum LineScoring {
    /// Epley estimated 1RM. Mirrors the server-side V1 formula.
    static func estimatedOneRepMax(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1 + Double(reps) / 30.0)
    }

    static func score(actualWeight: Double, actualReps: Int, against line: PerformanceLine) -> LineResult {
        let actual = estimatedOneRepMax(weight: actualWeight, reps: actualReps)
        let target = line.estimatedOneRepMax
        let score = target > 0 ? ((actual - target) / target) * 100 : 0
        return LineResult(actualE1RM: actual, targetE1RM: target, scorePercent: score)
    }
}
