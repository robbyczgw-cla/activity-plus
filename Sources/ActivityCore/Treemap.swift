import CoreGraphics
import Foundation

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000): rectangles whose areas are proportional
/// to the weights and whose sides stay close to square. Pure geometry, no UI.
public enum Treemap {
    /// One rectangle per weight, in input order. Weights should be sorted largest first for the best
    /// aspect ratios; zero or negative weights get an empty rectangle at the origin of `bounds`.
    public static func layout(_ weights: [Double], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: CGRect(origin: bounds.origin, size: .zero), count: weights.count)
        let positive = weights.indices.filter { weights[$0] > 0 && weights[$0].isFinite }
        let total = positive.reduce(0.0) { $0 + weights[$1] }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = positive.map { weights[$0] * scale }

        var free = bounds
        var start = 0
        while start < areas.count {
            let side = Double(min(free.width, free.height))
            // Grow the row while that does not make its worst aspect ratio worse.
            var end = start + 1
            var sum = areas[start]
            var smallest = areas[start]
            var largest = areas[start]
            var worstSoFar = worst(sum: sum, smallest: smallest, largest: largest, side: side)
            while end < areas.count {
                let nextSum = sum + areas[end]
                let candidate = worst(sum: nextSum, smallest: min(smallest, areas[end]), largest: max(largest, areas[end]), side: side)
                if candidate > worstSoFar { break }
                worstSoFar = candidate
                sum = nextSum
                smallest = min(smallest, areas[end])
                largest = max(largest, areas[end])
                end += 1
            }
            // The last row takes whatever space is left, so rounding never leaves a gap.
            let isLast = end == areas.count
            if free.width >= free.height {
                // Column along the left edge.
                let width = isLast ? Double(free.width) : min(Double(free.width), sum / Double(free.height))
                var y = Double(free.minY)
                for index in start ..< end {
                    let height = index == end - 1 ? Double(free.maxY) - y : areas[index] / width
                    result[positive[index]] = CGRect(x: Double(free.minX), y: y, width: width, height: max(0, height))
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                // Row along the top edge.
                let height = isLast ? Double(free.height) : min(Double(free.height), sum / Double(free.width))
                var x = Double(free.minX)
                for index in start ..< end {
                    let width = index == end - 1 ? Double(free.maxX) - x : areas[index] / height
                    result[positive[index]] = CGRect(x: x, y: Double(free.minY), width: max(0, width), height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
            start = end
        }
        return result
    }

    /// Worst aspect ratio of a row with total area `sum` laid along a side of length `side`.
    private static func worst(sum: Double, smallest: Double, largest: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0, side > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}
