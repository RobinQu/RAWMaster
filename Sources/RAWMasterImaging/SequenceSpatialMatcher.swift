import Foundation

public enum SequenceSpatialVerdict: String, Codable, Sendable { case supported, rejected, insufficient }
public enum SequenceSpatialReason: String, Codable, Sendable {
    case supported, smallImage, aspectMismatch, insufficientGlobalTexture, insufficientOverlap, ambiguousPeak
    case globalCorrelation, insufficientPatchTexture, patchSupport, centralMismatch
}
/// Bounded scalar summary. No arrays, pixels, paths, labels, duration, or class confidence.
public struct SequenceSpatialEvidence: Codable, Sendable, Equatable {
    public let verdict: SequenceSpatialVerdict
    public let reason: SequenceSpatialReason
    public let dx: Int?, dy: Int?
    public let overlap: Float?, correlation: Float?, peakMargin: Float?
    public let texturedPatches: Int, supportedPatches: Int, supportedQuadrants: Int
    public let centerSupported: Bool?
    public let maximumResidual: Float?
    public let coarseCandidates: Int, fineCandidates: Int, patchCandidates: Int
    public var candidateCount: Int { coarseCandidates + fineCandidates + patchCandidates }
    public var isFinite: Bool { [overlap, correlation, peakMargin, maximumResidual].allSatisfy { $0?.isFinite ?? true } }
}
public enum SequenceSpatialMatcher {
    public static let scratchReservationBytes = 512 * 1024
    private struct Candidate { let dx: Int, dy: Int; let score: Float; let overlap: Float }
    /// Directed source→target; source(x,y) corresponds to target(x+dx,y+dy).
    public static func compare(_ first: SequenceSpatialFeature, _ second: SequenceSpatialFeature,
                               configuration: SequenceSpatialConfiguration, cancelled: () -> Bool = { false }) throws -> SequenceSpatialEvidence {
        try configuration.validate(); try checkSpatialCancellation(cancelled)
        let c = configuration.recipe
        var coarseCount = 0, fineCount = 0, patchCount = 0, textured = 0, supported = 0, quadrants: Set<Int> = []
        var center: Bool?, residual: Float?, best: Candidate?, margin: Float?
        func result(_ verdict: SequenceSpatialVerdict, _ reason: SequenceSpatialReason) -> SequenceSpatialEvidence {
            SequenceSpatialEvidence(verdict: verdict, reason: reason, dx: best?.dx, dy: best?.dy, overlap: best?.overlap,
                correlation: best?.score, peakMargin: margin, texturedPatches: textured, supportedPatches: supported,
                supportedQuadrants: quadrants.count, centerSupported: center, maximumResidual: residual,
                coarseCandidates: coarseCount, fineCandidates: fineCount, patchCandidates: patchCount)
        }
        guard !first.isSmall, !second.isSmall else { return result(.insufficient, .smallImage) }
        let aspectA = Float(first.width) / Float(first.height), aspectB = Float(second.width) / Float(second.height)
        guard abs(aspectA / aspectB - 1) <= 0.01 else { return result(.insufficient, .aspectMismatch) }
        var coarseScores: [Candidate] = []
        for dy in -c.coarseRadius...c.coarseRadius { for dx in -c.coarseRadius...c.coarseRadius {
            try checkSpatialCancellation(cancelled); coarseCount += 1
            if let score = try overlapScore(first.coarse, second.coarse, side: 24, a: first.coarseValid, b: second.coarseValid,
                dx: dx, dy: dy, configuration: c, cancelled: cancelled) { coarseScores.append(score) }
        } }
        coarseScores.sort(by: preferred)
        guard let coarseBest = coarseScores.first else { return result(.insufficient, .insufficientGlobalTexture) }
        guard let other = coarseScores.first(where: { max(abs($0.dx - coarseBest.dx), abs($0.dy - coarseBest.dy)) > 1 }) else {
            return result(.insufficient, .ambiguousPeak)
        }
        margin = coarseBest.score - other.score
        guard margin! >= c.minimumPeakMargin else { return result(.insufficient, .ambiguousPeak) }
        for dy in max(-c.maximumTranslation, coarseBest.dy * 4 - c.fineRadius)...min(c.maximumTranslation, coarseBest.dy * 4 + c.fineRadius) {
            for dx in max(-c.maximumTranslation, coarseBest.dx * 4 - c.fineRadius)...min(c.maximumTranslation, coarseBest.dx * 4 + c.fineRadius) {
                try checkSpatialCancellation(cancelled); fineCount += 1
                if let score = try overlapScore(first.luminance, second.luminance, side: 96, a: first.valid, b: second.valid,
                    dx: dx, dy: dy, configuration: c, cancelled: cancelled), best == nil || preferred(score, best!) { best = score }
            }
        }
        guard let global = best else { return result(.insufficient, .insufficientOverlap) }
        guard global.score >= c.minimumCorrelation else { return result(.rejected, .globalCorrelation) }
        let half = c.patchSize / 2
        for row in 0..<3 { for column in 0..<3 {
            let cx = first.valid.x + (2 * column + 1) * first.width / 6
            let cy = first.valid.y + (2 * row + 1) * first.height / 6
            let x = cx - half, y = cy - half
            var local: Candidate?, localResidual: Float?
            for ry in -c.residualRadius...c.residualRadius { for rx in -c.residualRadius...c.residualRadius {
                try checkSpatialCancellation(cancelled); patchCount += 1
                let dx = global.dx + rx, dy = global.dy + ry
                // Complete fixed windows + the gradient neighborhood; padding/partial patches cannot score.
                guard first.valid.contains(x: x, y: y, width: c.patchSize, height: c.patchSize, margin: 1),
                      second.valid.contains(x: x+dx, y: y+dy, width: c.patchSize, height: c.patchSize, margin: 1),
                      let score = try score(first.luminance, second.luminance, side: 96, x: x, y: y, width: c.patchSize,
                        height: c.patchSize, dx: dx, dy: dy, minimumDeviation: c.minimumDeviation, cancelled: cancelled) else { continue }
                let gradients = try gradientScore(first, second, x: x, y: y, dx: dx, dy: dy, size: c.patchSize, cancelled: cancelled)
                guard gradients.meanA >= c.minimumGradient, gradients.meanB >= c.minimumGradient else { continue }
                let candidate = Candidate(dx: rx, dy: ry, score: score, overlap: 1)
                if local == nil || preferred(candidate, local!) { local = candidate; localResidual = gradients.cosine }
            } }
            guard let local else { continue }
            textured += 1
            let distance = sqrt(Float(local.dx * local.dx + local.dy * local.dy))
            let pass = local.score >= c.minimumCorrelation && (localResidual ?? -1) >= c.minimumGradientCosine && distance <= Float(c.residualRadius)
            if row == 1 && column == 1 { center = pass }
            if pass {
                supported += 1; residual = max(residual ?? 0, distance)
                if row != 1 && column != 1 { quadrants.insert(row < 1 ? (column < 1 ? 0 : 1) : (column < 1 ? 2 : 3)) }
            }
        } }
        try checkSpatialCancellation(cancelled)
        guard textured >= c.minimumTexturedPatches else { return result(.insufficient, .insufficientPatchTexture) }
        guard center != false else { return result(.rejected, .centralMismatch) }
        guard Float(supported) / Float(textured) >= c.minimumSupportedFraction, quadrants.count >= c.minimumQuadrants else { return result(.rejected, .patchSupport) }
        return result(.supported, .supported)
    }
    private static func preferred(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let da = a.dx*a.dx + a.dy*a.dy, db = b.dx*b.dx + b.dy*b.dy
        if da != db { return da < db }; if a.dy != b.dy { return a.dy < b.dy }; return a.dx < b.dx
    }
    private static func overlapScore(_ first: [Float], _ second: [Float], side: Int, a: SequenceSpatialRect, b: SequenceSpatialRect,
                                     dx: Int, dy: Int, configuration: SequenceSpatialRecipe, cancelled: () -> Bool) throws -> Candidate? {
        let x = max(a.x, b.x-dx), y = max(a.y, b.y-dy), maxX = min(a.maxX, b.maxX-dx), maxY = min(a.maxY, b.maxY-dy)
        guard maxX > x, maxY > y else { return nil }
        let overlap = Float((maxX-x)*(maxY-y)) / Float(min(a.area, b.area))
        guard overlap >= configuration.minimumOverlap,
              let value = try score(first, second, side: side, x: x, y: y, width: maxX-x, height: maxY-y,
                                    dx: dx, dy: dy, minimumDeviation: configuration.minimumDeviation, cancelled: cancelled) else { return nil }
        return Candidate(dx: dx, dy: dy, score: value, overlap: overlap)
    }
    private static func score(_ first: [Float], _ second: [Float], side: Int, x: Int, y: Int, width: Int, height: Int,
                              dx: Int, dy: Int, minimumDeviation: Float, cancelled: () -> Bool) throws -> Float? {
        var a = 0.0, b = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
        for row in y..<(y+height) {
            if (row-y).isMultiple(of: 8) { try checkSpatialCancellation(cancelled) }
            for column in x..<(x+width) {
                let firstValue = Double(first[row*side+column]), secondValue = Double(second[(row+dy)*side+column+dx])
                a += firstValue; b += secondValue; aa += firstValue*firstValue; bb += secondValue*secondValue; ab += firstValue*secondValue
            }
        }
        let n = Double(width * height), va = max(0, aa-a*a/n), vb = max(0, bb-b*b/n)
        guard va/n >= Double(minimumDeviation*minimumDeviation), vb/n >= Double(minimumDeviation*minimumDeviation) else { return nil }
        return Float(max(-1, min(1, (ab-a*b/n)/sqrt(va*vb))))
    }
    private static func gradientScore(_ first: SequenceSpatialFeature, _ second: SequenceSpatialFeature, x: Int, y: Int,
                                      dx: Int, dy: Int, size: Int, cancelled: () -> Bool) throws -> (meanA: Float, meanB: Float, cosine: Float) {
        var meanA: Float = 0, meanB: Float = 0, dot: Float = 0, normA: Float = 0, normB: Float = 0
        for row in y..<(y+size) {
            if (row-y).isMultiple(of: 8) { try checkSpatialCancellation(cancelled) }
            for column in x..<(x+size) {
                let a = row*96+column, b = (row+dy)*96+column+dx
                let ax = first.gradientX[a], ay = first.gradientY[a], bx = second.gradientX[b], by = second.gradientY[b]
                let na = ax*ax+ay*ay, nb = bx*bx+by*by
                meanA += sqrt(na); meanB += sqrt(nb); dot += ax*bx+ay*by; normA += na; normB += nb
            }
        }
        let cosine: Float = normA > 0 && normB > 0 ? max(-1, min(1, dot/sqrt(normA*normB))) : -1
        return (meanA/Float(size*size), meanB/Float(size*size), cosine)
    }
}
