import Foundation

/// Tiny median filter for noisy per-frame joint angles.
/// A median window is intentionally used instead of a heavy ML/filtering layer:
/// it kills single-frame Vision spikes without adding much lag to a rep.
struct AngleSmoother {
    let windowSize: Int
    private var samples: [Double] = []

    init(windowSize: Int = 5) {
        precondition(windowSize > 0)
        self.windowSize = windowSize
    }

    mutating func add(_ value: Double) -> Double {
        guard value.isFinite else { return samples.last ?? 0 }
        samples.append(value)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }

        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
