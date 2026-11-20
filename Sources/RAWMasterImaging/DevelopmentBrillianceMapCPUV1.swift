import Foundation

/// Typed CPU translation of the independently qualified map generator.
/// Input is the actual joined top-to-bottom linear-sRGB BGRA8 proxy, not FIT.
enum BrillianceMapCPU {
    static let grid = 31
    static let targetPixels = 0x40000
    struct Scale: Equatable {
        let numerator, denominator, width, height: Int
        let branch: String
    }
    struct Result {
        let bytes: Data
        let stepX, stepY: Int
    }
    static let slope = Double(bitPattern: 0x400387B1E1387B2D)
    static let intercept = Double(bitPattern: 0xBFF0FDBC090FDBCD)
    static let packBias = Double(bitPattern: 0x3FF3333333333333)
    static let packScale = Double(bitPattern: 0x3FD2D2DCB1465E89)
    static let u8Max = Double(bitPattern: 0x406FE00000000000)
    static let cdfEpsilon = Double(bitPattern: 0x37A16C262777579C)
    static let p98Threshold = Double(bitPattern: 0x3FEF5C28F5C28F5C)

    static func scale(width: Int, height: Int) throws -> Scale {
        guard width > 0, height > 0, width <= Int32.max, height <= Int32.max else {
            throw PublicBrillianceError.invalid("positive bounded native dimensions")
        }
        let ratio = Double(width) / Double(height)
        let h1 = Int(floor(sqrt(Double(targetPixels) / ratio)))
        let w1 = Int(ceil(ratio * Double(h1)))
        let w2 = Int(floor(sqrt(Double(targetPixels) * ratio)))
        let h2 = Int(ceil(Double(w2) / ratio))
        let area1 = w1 * h1, area2 = w2 * h2
        let heightArm = area1 < area2 ? area2 > targetPixels : area1 <= targetPixels
        let n = heightArm ? h1 : w2, d = heightArm ? height : width
        if n > d { return Scale(numerator: 1, denominator: 1, width: width, height: height, branch: "clamped-identity") }
        return Scale(numerator: n, denominator: d, width: heightArm ? w1 : w2,
                     height: heightArm ? h1 : h2, branch: heightArm ? "height" : "width")
    }

    static func rounded(_ value: Double) throws -> Int {
        guard value.isFinite, value > Double(Int.min), value < Double(Int.max) else {
            throw PublicBrillianceError.invalid("finite bounded rounded value")
        }
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }

    static func encode(p50: Double, p98: Double) throws -> (UInt8, UInt8) {
        guard p50 >= 0, p50 <= p98, p98 <= 1 else { throw PublicBrillianceError.invalid("local percentiles") }
        let c0 = Float(intercept.addingProduct(p50, slope))
        let c2 = Float(p98)
        let first = try rounded(((Double(c0) + packBias) * packScale) * u8Max)
        let second = try rounded(Double(c2 * Float(u8Max)))
        guard (0...255).contains(first), (0...255).contains(second) else {
            throw PublicBrillianceError.invalid("map code outside UInt8")
        }
        return (UInt8(first), UInt8(second))
    }

    static func percentiles(_ counts: [Int], endX: Int, endY: Int) throws -> (Double, Double) {
        guard counts.count == 256, counts.allSatisfy({ $0 >= 0 }) else {
            throw PublicBrillianceError.invalid("histogram")
        }
        var bins = [Double](repeating: 0, count: 256)
        if counts.contains(where: { $0 != 0 }) {
            guard endX > 0, endY > 0 else { throw PublicBrillianceError.invalid("nonempty cell end") }
            let weight = 1 / Double(endX * endY)
            for index in counts.indices {
                // Deliberate repeated Double additions. Multiplication changes rounding.
                for _ in 0..<counts[index] { bins[index] = bins[index] + weight }
            }
        }
        var total = cdfEpsilon
        for bin in bins { total += bin }
        var cumulative = 0.0, p50 = 0.0, p98 = 0.0
        for index in bins.indices {
            cumulative += bins[index]
            let cdf = cumulative / total
            if p50 == 0 && cdf >= 0.5 { p50 = Double(index) / u8Max }
            if p98 == 0 && cdf >= p98Threshold { p98 = Double(index) / u8Max }
        }
        return (p50, p98)
    }

    static func layout(width: Int, height: Int, bytesPerRow: Int, byteCount: Int) throws -> (Int, Int) {
        guard (16...4096).contains(width), (16...4096).contains(height),
              bytesPerRow >= width * 4, byteCount > 0, byteCount <= 16 * 1024 * 1024,
              bytesPerRow <= 16 * 1024 * 1024 / height, byteCount == height * bytesPerRow else {
            throw PublicBrillianceError.invalid("bounded proxy layout")
        }
        let dx = try rounded(Double(Float(width) / Float(grid)))
        let dy = try rounded(Double(Float(height) / Float(grid)))
        // Check every cell before reading. The original rounded grid may leave an
        // edge strip unused; it must not be silently stretched or redistributed.
        for row in 0..<grid {
            for column in 0..<grid {
                let x0 = column * dx, y0 = row * dy
                let x1 = min(x0 + dx, width), y1 = min(y0 + dy, height)
                guard x0 >= 0, y0 >= 0, x1 >= 0, y1 >= 0, x1 <= width, y1 <= height,
                      x1 <= width, y1 <= height else { throw PublicBrillianceError.invalid("cell outside proxy") }
            }
        }
        return (dx, dy)
    }

    static func generate(_ storage: Data, width: Int, height: Int, bytesPerRow: Int,
                         check: () throws -> Void = {}) throws -> Result {
        let (dx, dy) = try layout(width: width, height: height, bytesPerRow: bytesPerRow, byteCount: storage.count)
        var output = Data(capacity: grid * grid * 2)
        try storage.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for row in 0..<grid {
                try check()
                for column in 0..<grid {
                    let x0 = column * dx, y0 = row * dy
                    let x1 = min(x0 + dx, width), y1 = min(y0 + dy, height)
                    var counts = [Int](repeating: 0, count: 256)
                    if x0 < x1 && y0 < y1 {
                      for y in y0..<y1 {
                        for x in x0..<x1 {
                            let p = y * bytesPerRow + x * 4
                            let rg = Double(bytes[p + 2]) / u8Max + Double(bytes[p + 1]) / u8Max
                            let rgb = rg + Double(bytes[p]) / u8Max
                            let bin = min(255, Int(floor((rgb / 3) * 256)))
                            counts[bin] += 1
                        }
                    }
                    }
                    guard counts.reduce(0, +) == max(0, x1 - x0) * max(0, y1 - y0) else {
                        throw PublicBrillianceError.invalid("histogram cell count")
                    }
                    let (p50, p98) = try percentiles(counts, endX: x1, endY: y1)
                    let (r, g) = try encode(p50: p50, p98: p98)
                    output.append(r); output.append(g)
                }
            }
        }
        try check()
        guard output.count == 1922 else { throw PublicBrillianceError.invalid("map storage size") }
        return Result(bytes: output, stepX: dx, stepY: dy)
    }
}
