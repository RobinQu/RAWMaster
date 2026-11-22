import Foundation
import XCTest

/// Evaluate Y' and the two independent color differences in native-display RGB8 codes.
/// Samples close to a display boundary can clip when encoded to an 8-bit CGImage.
enum PhotoDenoiseComponentWitness {
    static func evaluate(original: Data, zero: Data, half: Data, full: Data) throws -> [String: Any] {
        let frames = [original, zero, half, full]
        guard Set(frames.map(\.count)).count == 1, original.count % 4 == 0 else {
            throw NSError(domain: "PhotoDenoiseComponentWitness", code: 1)
        }
        var zeroLuma = [Double](), halfLuma = [Double](), chroma = [Double]()
        var changedColor = 0, changedLuma = 0
        for i in stride(from: 0, to: original.count, by: 4) {
            guard frames.allSatisfy({ $0[i + 3] == 255 }) else { continue }
            let rgb = frames.map { data in [Double(data[i]), Double(data[i + 1]), Double(data[i + 2])] }
            guard rgb.allSatisfy({ $0.allSatisfy { (4...251).contains($0) } }) else { continue }
            let y = rgb.map { 0.2126 * $0[0] + 0.7152 * $0[1] + 0.0722 * $0[2] }
            zeroLuma.append(abs(y[1] - y[0]))
            halfLuma.append(abs(y[2] - (y[0] + y[3]) / 2))
            var error = 0.0, change = 0.0
            for c in [0, 2] {
                let predicted = rgb[3][c] - y[3]
                change = max(change, abs(rgb[0][c] - y[0] - predicted))
                error = max(error, abs(rgb[1][c] - y[1] - predicted), abs(rgb[2][c] - y[2] - predicted))
            }
            chroma.append(error)
            changedColor += change >= 2 ? 1 : 0
            changedLuma += abs(y[3] - y[0]) >= 2 ? 1 : 0
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        XCTAssertGreaterThan(zeroLuma.count, 1_000)
        guard !zeroLuma.isEmpty else { throw NSError(domain: "PhotoDenoiseComponentWitness", code: 2) }
        let zeroError = p95(zeroLuma), halfError = p95(halfLuma), chromaError = p95(chroma)
        XCTAssertLessThanOrEqual(zeroError, 1.5, "Amount 0 preserves source luma")
        XCTAssertLessThanOrEqual(halfError, 1.5, "Amount 50 is halfway to predicted luma")
        XCTAssertLessThanOrEqual(chromaError, 2, "Amounts 0 and 50 retain full predicted chroma")
        XCTAssertGreaterThan(changedColor, 32, "Enough independent color detail must change to detect a passthrough")
        XCTAssertGreaterThan(changedLuma, 32, "The intensity comparison needs samples affected by luma denoising")
        return ["sampled": original.count / 4, "inRangeOpaque": zeroLuma.count,
                "sourceToFullChromaChangedByTwoCodes": changedColor, "sourceToFullLumaChangedByTwoCodes": changedLuma,
                "p95ZeroVsSourceLumaRGB8": zeroError, "p95HalfVsMidpointLumaRGB8": halfError,
                "p95ZeroAndHalfVsFullChromaRGB8": chromaError]
    }
}
