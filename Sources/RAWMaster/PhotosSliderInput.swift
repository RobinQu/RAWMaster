import Foundation

/// Slider-only input policy. Numeric fields and saved values never pass through this rounding.
enum PhotosSliderInput {
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
}
