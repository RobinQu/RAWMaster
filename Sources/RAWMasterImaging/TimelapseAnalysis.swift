import CoreGraphics
import CoreImage
import Foundation
import RAWMasterCore
import Vision

enum TimelapseAnalysis {
    static let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    /// Boundary-aware local linear fit, so a genuine log-luminance ramp is unchanged even at its ends.
    static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        return values.indices.map { index in
            let lower = max(0, index - radius), upper = min(values.count - 1, index + radius)
            var weight = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for i in lower...upper {
                let x = Double(i - index), w = Double(radius + 1) - abs(x)
                weight += w; sx += w*x; sy += w*values[i]; sxx += w*x*x; sxy += w*x*values[i]
            }
            let determinant = weight*sxx - sx*sx
            return determinant > 1e-9 ? (sy*sxx - sx*sxy) / determinant : values[index]
        }
    }
    static func exposureCorrections(logLuminances: [Double], strength: Double, radius: Int) -> [Double] {
        let trend = smooth(logLuminances, radius: radius)
        return zip(trend, logLuminances).map { max(-1, min(1, ($0 - $1) * strength)) }
    }

    static func corrections(offsets: [SIMD2<Double>], settings: TimelapseSettings) -> (values: [SIMD2<Double>], crop: Double, fallback: Bool) {
        guard settings.alignment != .off else { return (Array(repeating: .zero, count: offsets.count), 0, false) }
        let x = smooth(offsets.map(\.x), radius: settings.smoothingRadius)
        let y = smooth(offsets.map(\.y), radius: settings.smoothingRadius)
        let values = offsets.enumerated().map { index, offset in
            settings.alignment == .subject ? offset : offset - SIMD2(x[index], y[index])
        }
        let crop = values.reduce(0) { max($0, max(abs($1.x), abs($1.y))) }
        guard crop <= settings.maxCropFraction else { return (Array(repeating: .zero, count: offsets.count), 0, true) }
        return (values, crop, false)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    static func rectangle(_ region: TimelapseRegion, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + region.x * extent.width, y: extent.minY + region.y * extent.height,
               width: region.width * extent.width, height: region.height * extent.height)
    }
    static func luminances(_ image: CIImage, context: CIContext, region: CGRect? = nil) -> [Double] {
        let area = region ?? image.extent
        let cropped = normalized(image.cropped(to: area))
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: 64 / cropped.extent.width, y: 64 / cropped.extent.height))
        var samples = [Float](repeating: 0, count: 64*64*4)
        samples.withUnsafeMutableBytes { bytes in
            context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: 64*4*MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: linearSpace)
        }
        return (0..<(64*64)).map { (i: Int) -> Double in
            let r = Double(samples[i*4]), g = Double(samples[i*4+1]), b = Double(samples[i*4+2])
            return max(0, r * 0.2126 + g * 0.7152 + b * 0.0722)
        }
    }
    static func logLuminance(_ image: CIImage, context: CIContext, region: CGRect) -> Double {
        let values = luminances(image, context: context, region: region).filter { $0.isFinite }.sorted()
        return log2(max(0.0001, values.isEmpty ? 0.0001 : values[values.count / 2]))
    }

    /// Vision's target is the floating/current image; the handler is the reference.
    /// Returned translation maps current → reference in the full proxy's normalized coordinates.
    static func translation(reference: CGImage, current: CGImage, region: TimelapseRegion?, context: CIContext) throws -> SIMD2<Double>? {
        try Task.checkCancellation()
        guard reference.width == current.width, reference.height == current.height else { return nil }
        let full = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        let roi = region.map { rectangle($0, in: full).integral.intersection(full) } ?? full
        guard roi.width >= 32, roi.height >= 32,
              let first = context.createCGImage(normalized(CIImage(cgImage: reference).cropped(to: roi)), from: CGRect(origin: .zero, size: roi.size)),
              let second = context.createCGImage(normalized(CIImage(cgImage: current).cropped(to: roi)), from: CGRect(origin: .zero, size: roi.size)) else { return nil }
        let a = luminances(CIImage(cgImage: first), context: context)
        let b = luminances(CIImage(cgImage: second), context: context)
        guard deviation(a) > 0.008, deviation(b) > 0.008 else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: second, options: [:])
        do { try VNImageRequestHandler(cgImage: first, options: [:]).perform([request]) }
        catch { try Task.checkCancellation(); return nil }
        try Task.checkCancellation()
        guard let observation = request.results?.first, observation.confidence >= 0.1 else { return nil }
        let transform = observation.alignmentTransform
        guard transform.tx.isFinite, transform.ty.isFinite,
              abs(transform.tx) <= roi.width * 0.3, abs(transform.ty) <= roi.height * 0.3 else { return nil }
        let referenceImage = CIImage(cgImage: first), floating = CIImage(cgImage: second).transformed(by: transform)
        let overlap = referenceImage.extent.intersection(floating.extent)
        guard overlap.width * overlap.height >= roi.width * roi.height * 0.65 else { return nil }
        let referenceValues = luminances(referenceImage, context: context, region: overlap)
        let currentValues = luminances(floating, context: context, region: overlap)
        guard correlation(referenceValues, currentValues) > 0.72 else { return nil }
        return SIMD2(Double(transform.tx) / Double(reference.width), Double(transform.ty) / Double(reference.height))
    }
    static func deviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0,+) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + ($1-mean)*($1-mean) } / Double(values.count))
    }
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let ma = a.reduce(0,+)/Double(a.count), mb = b.reduce(0,+)/Double(b.count)
        var numerator = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices { let x=a[i]-ma, y=b[i]-mb; numerator += x*y; aa += x*x; bb += y*y }
        return numerator / max(1e-12,sqrt(aa*bb))
    }
}
