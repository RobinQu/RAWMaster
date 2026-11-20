import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum PublicBrillianceError: Error {
    case invalid(String)
}

struct FixedBlurAxis {
    let ratio: Float
    let sigma: Float
    let reductions: [Int]
    let residualVariance: Double
    let offsets: [Double]
    let weights: [Double]

    init(length: Int) {
        ratio = Float(length) / Float(31)
        sigma = ratio * Float(0.4)
        var variance = Double(sigma) * Double(sigma)
        var reductions: [Int] = []
        for (factor, correction) in [(4, -9.9225), (2, -3.0625)] {
            let squared = Double(factor * factor)
            while (variance + correction) / squared >= 0.35809962195672995 {
                variance = (variance + correction) / squared
                reductions.append(factor)
            }
        }
        self.reductions = reductions
        if !reductions.isEmpty { variance -= 0.35809862195673 }
        residualVariance = variance
        let residual = sqrt(variance)
        var tap: [Double]
        if residual < 0.570644 {
            let wing = max(0, (residual * 0.14).addingProduct(variance, 0.33) - 0.036442)
            tap = Array(repeating: 0, count: 8) + [wing, 1.0.addingProduct(-2, wing)]
        } else {
            tap = (-9...0).map { offset in
                exp(Double(-offset * offset) / (residual * (residual + residual))) / (residual * 2.5066282746310002)
            }
        }
        var tail = 0.0
        for index in tap.indices {
            tail += tap[index]
            if tail >= Double(Float(0.003)) {
                tap[index] = tail
                break
            }
            tap[index] = 0
        }
        let fromCenter = Array(tap.reversed())
        var weights: [Double] = [], offsets: [Double] = []
        for pair in 0..<5 {
            let index = pair * 2
            let a = pair == 0 ? 0.5 * fromCenter[0] : fromCenter[index]
            let b = fromCenter[index + 1]
            let weight = a + b
            weights.append(weight)
            offsets.append(pair == 0 ? b / weight : (weight >= 1e-5 ? Double(index) + b / weight : 0))
        }
        self.weights = weights
        self.offsets = offsets
    }
}

// CIImageProvider's rows start at the upper left, matching the archived stream.
final class MapRows: NSObject {
    private var storage:Data?
    var bytes:Data{storage!}
    let width: Int
    let height: Int
    private let reservation:PreviewPresentationReservation?
    deinit {storage=nil;reservation?.releaseAfterStorageReleased()}

    init(_ bytes: Data, width: Int, height: Int, reservation:PreviewPresentationReservation? = nil) throws {
        guard (1...31).contains(width), (1...31).contains(height), bytes.count == 2 * width * height else {
            throw PublicBrillianceError.invalid("map dimensions or byte count")
        }
        self.reservation=reservation
        self.storage = bytes
        self.width = width
        self.height = height
    }

    override func provideImageData(_ destination: UnsafeMutableRawPointer, bytesPerRow rowBytes: Int,
                                   origin x: Int, _ y: Int, size columns: Int, _ rows: Int, userInfo info: Any?) {
        precondition(x >= 0 && x <= width && y >= 0 && y <= height)
        precondition(columns >= 0 && columns <= width - x && rows >= 0 && rows <= height - y)
        precondition(rowBytes >= columns * 2)
        bytes.withUnsafeBytes { source in
            for row in 0..<rows {
                destination.advanced(by: row * rowBytes).copyMemory(
                    from: source.baseAddress!.advanced(by: ((y + row) * width + x) * 2),
                    byteCount: columns * 2)
            }
        }
    }

    func image() -> CIImage {
        CIImage(imageProvider: self, size: width, height, format: .RG8, colorSpace: nil, options: nil)
    }
}

struct BrilliancePlan {
    let extent: CGRect
    let x: FixedBlurAxis
    let y: FixedBlurAxis
    let reductions: [(factor: Int, horizontal: Bool)]
    let inverseX: Float
    let inverseY: Float

    init(extent: CGRect) throws {
        guard !extent.isNull, !extent.isInfinite, extent.origin == .zero,
              extent.width.isFinite, extent.height.isFinite,
              extent.width.rounded(.down) == extent.width, extent.height.rounded(.down) == extent.height,
              extent.width > 0, extent.height > 0,
              extent.width <= CGFloat(Int32.max), extent.height <= CGFloat(Int32.max) else {
            throw PublicBrillianceError.invalid("finite integral normalized native extent")
        }
        self.extent = extent
        x = FixedBlurAxis(length: Int(extent.width))
        y = FixedBlurAxis(length: Int(extent.height))
        // An identity axis needs its own restore rule. Do not silently apply the
        // two-dimensional SoftCubic restore to an axis which was not reduced.
        guard !x.reductions.isEmpty, !y.reductions.isEmpty,
              x.weights.allSatisfy({ $0.isFinite && $0 >= 0 }),
              y.weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw PublicBrillianceError.invalid("unreduced-axis restore is not yet qualified")
        }
        inverseX = 1 / Float(x.reductions.reduce(1, *))
        inverseY = 1 / Float(y.reductions.reduce(1, *))
        var order: [(Int, Bool)] = []
        // Factor group, pass, then X/Y: chart control remains 4X,4Y,2X,2Y.
        for factor in [4, 2] {
            let nx = x.reductions.filter { $0 == factor }.count
            let ny = y.reductions.filter { $0 == factor }.count
            for pass in 0..<max(nx, ny) {
                if pass < nx { order.append((factor, true)) }
                if pass < ny { order.append((factor, false)) }
            }
        }
        reductions = order
    }
}

enum PublicBrilliance {
    static let x = FixedBlurAxis(length: 1024)
    static let y = FixedBlurAxis(length: 768)
    static let extent = CGRect(x: 0, y: 0, width: 1024, height: 768)

    private static let generalKernels = NSCache<NSString, CIKernel>()
    private static let colorKernels = NSCache<NSString, CIColorKernel>()

    static func general(_ source: String) throws -> CIKernel {
        let key = source as NSString
        if let cached = generalKernels.object(forKey: key) { return cached }
        guard let kernel = CIKernel(source: source) else { throw PublicBrillianceError.invalid("CIKernel compilation") }
        generalKernels.setObject(kernel, forKey: key)
        return kernel
    }

    static func color(_ source: String) throws -> CIColorKernel {
        let key = source as NSString
        if let cached = colorKernels.object(forKey: key) { return cached }
        guard let kernel = CIColorKernel(source: source) else { throw PublicBrillianceError.invalid("CIColorKernel compilation") }
        colorKernels.setObject(kernel, forKey: key)
        return kernel
    }

    static func apply(_ kernel: CIKernel, _ args: [Any], extent: CGRect = .infinite, observedStage: String? = nil,
                      roi: @escaping CIKernelROICallback = { _, rect in rect }) throws -> CIImage {
        guard let output = kernel.apply(extent: extent, roiCallback: roi, arguments: args) else {
            throw PublicBrillianceError.invalid("general kernel apply")
        }
        return output
    }

    static func apply(_ kernel: CIColorKernel, _ args: [Any], extent: CGRect = .infinite) throws -> CIImage {
        guard let output = kernel.apply(extent: extent, arguments: args) else {
            throw PublicBrillianceError.invalid("color kernel apply")
        }
        return output
    }

    static func active(_ amount: Double) -> Bool { abs(amount) >= 1e-10 }

    static func graph(image: CIImage, provider: MapRows?, local: Double, shadow: Double,
                      observeTiledJoint: ((CGRect) -> Void)? = nil) throws -> CIImage {
        guard local.isFinite, shadow.isFinite else { throw PublicBrillianceError.invalid("nonfinite adjustment") }
        guard active(local) || active(shadow) else { return image }
        let originalAdjustment=try Self.adjustment(image:image,provider:provider)
        let adjustment: CIImage
        if let observeTiledJoint {
            guard #available(macOS 26.0, *) else { throw PublicBrillianceError.invalid("public tiled joint unavailable") }
            let tiled = originalAdjustment.insertingTiledIntermediate()
            guard tiled !== originalAdjustment, tiled.extent == originalAdjustment.extent,
                  tiled.extent == image.extent else { throw PublicBrillianceError.invalid("actual tiled joint extent/identity") }
            adjustment = tiled
            observeTiledJoint(tiled.extent)
        } else {
            adjustment = originalAdjustment
        }
        var result = image
        if active(local) { result = try apply(color(Kernels.poly), [result, adjustment, local], extent: image.extent) }
        if active(shadow) { result = try apply(color(Kernels.shadow), [result, adjustment, shadow], extent: image.extent) }
        return result
    }

    /// Original full-native two-channel adjustment, with no materialization policy.
    /// Both channels are needed by poly (r strength and g pivot).
    static func adjustment(image:CIImage,provider:MapRows?)throws->CIImage {
        let plan = try BrilliancePlan(extent: image.extent)
        guard let provider, provider.width == 31, provider.height == 31 else {
            throw PublicBrillianceError.invalid("native prepared map dimensions")
        }
        let x = plan.x, y = plan.y
        let transfer = CIFilter.linearToSRGBToneCurve()
        transfer.inputImage = image
        guard let encoded = transfer.outputImage else { throw PublicBrillianceError.invalid("guide transfer") }
        let mono = try apply(color(Kernels.mono), [encoded.clampedToExtent()])
        let blurred = try blur(mono, plan: plan)
        let map = provider.image().clampedToExtent().transformed(
            by: CGAffineTransform(scaleX: CGFloat(x.ratio), y: CGFloat(y.ratio)))
        let combined = try combine(mono, blurred, map)
        return try joint(combined, xRatio: x.ratio, yRatio: y.ratio, crop: image.extent)
    }

    static func combine(_ guide: CIImage, _ blur: CIImage, _ map: CIImage) throws -> CIImage {
        try apply(color(Kernels.combine), [guide, blur, map])
    }

    static func joint(_ combined: CIImage, xRatio: Float, yRatio: Float, crop: CGRect) throws -> CIImage {
        let luma = Double(Float(0.15))
        let parameters = CIVector(x: 1 / (2 * luma * luma), y: 1 / (2 * 5 * 5),
                                  z: Double(xRatio) * 0.6666667, w: Double(yRatio) * 0.6666667)
        return try apply(general(Kernels.joint), [combined, parameters], observedStage: "joint") { _, rect in
            rect.insetBy(dx: -1.34 * CGFloat(xRatio), dy: -1.34 * CGFloat(yRatio)).integral
        }.cropped(to: crop)
    }

    private static func residual(_ input: CIImage, axis: FixedBlurAxis, horizontal: Bool) throws -> CIImage {
        // Keep the original chart expression, including its zero-weight pairs.
        // Include every additional nonzero pair for larger residual support.
        let minimum = horizontal ? 3 : 2
        let pairs = max(minimum, (axis.weights.lastIndex(where: { $0 != 0 }) ?? 0) + 1)
        let o = axis.offsets, w = axis.weights
        let direction: (Double) -> CIVector = { value in
            CIVector(x: horizontal ? value : 0, y: horizontal ? 0 : value)
        }
        let kernel: CIKernel
        let arguments: [Any]
        if pairs == 2 {
            kernel = try general(Kernels.blur7)
            arguments = [input, CIVector(x: horizontal ? o[0] : 0, y: horizontal ? 0 : o[0],
                                        z: horizontal ? o[1] : 0, w: horizontal ? 0 : o[1]),
                         CIVector(x: w[0], y: w[1])]
        } else if pairs == 3 {
            kernel = try general(Kernels.blur11)
            arguments = [input, CIVector(x: horizontal ? o[0] : 0, y: horizontal ? 0 : o[0],
                                        z: horizontal ? o[1] : 0, w: horizontal ? 0 : o[1]),
                         direction(o[2]), CIVector(x: w[0], y: w[1], z: w[2], w: 0)]
            // blur11 takes a vec4 for its last offset; pad the actual argument.
            var padded = arguments
            padded[2] = CIVector(x: horizontal ? o[2] : 0, y: horizontal ? 0 : o[2], z: 0, w: 0)
            return try apply(kernel, padded, observedStage: horizontal ? "residual-x" : "residual-y") { _, rect in
                rect.isEmpty ? rect : rect.insetBy(dx: horizontal ? -5 : 0, dy: horizontal ? 0 : -5).integral
            }
        } else {
            guard (4...5).contains(pairs) else { throw PublicBrillianceError.invalid("bounded residual pairs") }
            kernel = try general(Kernels.residual(pairs: pairs))
            arguments = [input] + (0..<pairs).map { direction(o[$0]) as Any } + (0..<pairs).map { w[$0] as Any }
        }
        let radius = CGFloat(pairs * 2 - 1)
        return try apply(kernel, arguments, observedStage: horizontal ? "residual-x" : "residual-y") { _, rect in
            rect.isEmpty ? rect : rect.insetBy(dx: horizontal ? -radius : 0, dy: horizontal ? 0 : -radius).integral
        }
    }

    private static func blur(_ guide: CIImage, plan: BrilliancePlan) throws -> CIImage {
        let reduction4 = try general(Kernels.reduce4)
        let reduction2 = try general(Kernels.reduce2)
        var input = guide
        for (reductionIndex, step) in plan.reductions.enumerated() {
            let factor = CGFloat(step.factor), horizontal = step.horizontal
            let padding: CGFloat = step.factor == 4 ? 7 : 4
            let kernel = step.factor == 4 ? reduction4 : reduction2
            let sx = horizontal ? factor : 1, sy = horizontal ? 1 : factor
            let padX = horizontal ? padding : 0, padY = horizontal ? 0 : padding
            let scale = CIVector(x: sx, y: sy, z: horizontal ? 1 : 0, w: horizontal ? 0 : 1)
            input = try apply(kernel, [input, scale], observedStage: "reduce\(step.factor)-\(horizontal ? "x" : "y")-\(reductionIndex)") { _, rect in
                guard !rect.isEmpty else { return rect }
                return CGRect(x: sx * rect.minX - padX, y: sy * rect.minY - padY,
                              width: sx * rect.width + 2 * padX, height: sy * rect.height + 2 * padY).integral
            }
        }
        input = try residual(input, axis: plan.x, horizontal: true)
        input = try residual(input, axis: plan.y, horizontal: false)
        return try apply(general(Kernels.restore), [input, CIVector(x: CGFloat(plan.inverseX), y: CGFloat(plan.inverseY))], observedStage: "restore") { _, rect in
            restoreROI(rect, inverseX: plan.inverseX, inverseY: plan.inverseY)
        }
    }

    static func restoreROI(_ rect: CGRect, inverseX: Float = 0.125, inverseY: Float = 0.125) -> CGRect {
        guard !rect.isEmpty, !rect.isInfinite else { return rect }
        func bounds(_ value: CGFloat, inverse: Float) -> (CGFloat, CGFloat) {
            let coordinate = Float(-0.5).addingProduct(Float(value), inverse)
            let cell = floor(coordinate)
            let right = coordinate - cell
            let left = (cell - coordinate) + 1
            return (CGFloat(cell.addingProduct(left, left * -0.2) + 0.5),
                    CGFloat(cell.addingProduct(right, right * 0.2) + 1.5))
        }
        let minX = bounds(rect.minX, inverse: inverseX)
        let minY = bounds(rect.minY, inverse: inverseY)
        let maxX = bounds(rect.maxX, inverse: inverseX)
        let maxY = bounds(rect.maxY, inverse: inverseY)
        let left = min(minX.0, minX.1, maxX.0, maxX.1)
        let bottom = min(minY.0, minY.1, maxY.0, maxY.1)
        let right = max(minX.0, minX.1, maxX.0, maxX.1)
        let top = max(minY.0, minY.1, maxY.0, maxY.1)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            .insetBy(dx: 0.0001, dy: 0.0001).integral.insetBy(dx: -1, dy: -1)
    }
}
