import Foundation

/// Slider-only input policy. Numeric fields and saved values never pass through this rounding.
enum PhotosSliderInput {
    static func fraction(_ value: Double, range: ClosedRange<Double>) -> Double {
        guard range.lowerBound < range.upperBound else { return 0 }
        return (min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    static func fill(value: Double, range: ClosedRange<Double>) -> ClosedRange<Double> {
        let base = range.lowerBound < 0 && range.upperBound > 0 ? fraction(0, range: range) : 0
        let end = fraction(value, range: range)
        return min(base, end)...max(base, end)
    }
    static func snapped(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double? {
        guard value.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
              step.isFinite, step > 0 else { return nil }
        if value <= range.lowerBound { return range.lowerBound }
        if value >= range.upperBound { return range.upperBound }
        let index = ((value - range.lowerBound) / step).rounded()
        let result = range.lowerBound + index * step
        guard result.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, result))
    }
    static func scrubbed(origin: Double, translation: Double, range: ClosedRange<Double>, step: Double) -> Double? {
        guard origin.isFinite, translation.isFinite, range.upperBound >= range.lowerBound else { return nil }
        let candidate = origin + translation / 200 * (range.upperBound - range.lowerBound)
        return snapped(candidate, range: range, step: step)
    }
}
