import Foundation

enum FaceGeometry {
    static let leftEye = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
    static let rightEye = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398]
    static let leftIris = [469, 470, 471, 472]
    static let rightIris = [474, 475, 476, 477]
    static let leftEyebrow = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]
    static let rightEyebrow = [300, 293, 334, 296, 336, 285, 295, 282, 283, 276]
    static let outerLips = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95, 78, 191, 80, 81, 82, 13, 312, 311, 310, 415]
    static let innerMouth = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191]

    static func rasterize(points: [NormalizedPoint], polygons: [[Int]], subtract: [[Int]] = [],
                          width: Int, height: Int) throws -> MaskImage {
        guard points.count >= 478 else { throw MaskAIError.invalidInput("Face geometry needs 478 landmarks.") }
        var values = [UInt8](repeating: 0, count: width * height)
        for polygon in polygons { try paint(polygon: polygon, points: points, values: &values, width: width, height: height, add: true) }
        for polygon in subtract { try paint(polygon: polygon, points: points, values: &values, width: width, height: height, add: false) }
        return try MaskImage(width: width, height: height, values: values)
    }

    static func teeth(points: [NormalizedPoint], image: NativeImage) throws -> MaskImage {
        let mouth = try rasterize(points: points, polygons: [innerMouth], width: image.width, height: image.height)
        let values = mouth.values.enumerated().map { index, selected -> UInt8 in
            guard selected > 0 else { return 0 }
            let red = Float(image.rgba[index * 4]) / 255, green = Float(image.rgba[index * 4 + 1]) / 255, blue = Float(image.rgba[index * 4 + 2]) / 255
            let high = max(red, green, blue), low = min(red, green, blue)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let saturation = high > 0 ? (high - low) / high : 0
            let bright = min(1, max(0, (luminance - 0.4) / 0.25))
            let neutral = min(1, max(0, (0.55 - saturation) / 0.35))
            return UInt8((255 * bright * neutral).rounded().clamped(to: 0...255))
        }
        return try MaskImage(width: image.width, height: image.height, values: values)
    }

    private static func paint(polygon: [Int], points: [NormalizedPoint], values: inout [UInt8], width: Int, height: Int, add: Bool) throws {
        guard polygon.count >= 3, polygon.allSatisfy({ $0 >= 0 && $0 < points.count }) else {
            throw MaskAIError.invalidInput("Invalid face polygon.")
        }
        let polygonPoints = polygon.map { points[$0] }
        let minX = max(0, Int((polygonPoints.map(\.x).min()! * Double(width)).rounded(.down)))
        let maxX = min(width - 1, Int((polygonPoints.map(\.x).max()! * Double(width)).rounded(.up)))
        let minY = max(0, Int((polygonPoints.map(\.y).min()! * Double(height)).rounded(.down)))
        let maxY = min(height - 1, Int((polygonPoints.map(\.y).max()! * Double(height)).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let point = NormalizedPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
                if contains(point: point, polygon: polygonPoints) { values[y * width + x] = add ? 255 : 0 }
            }
        }
    }

    private static func contains(point: NormalizedPoint, polygon: [NormalizedPoint]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current], b = polygon[previous]
            let intersects = (a.y > point.y) != (b.y > point.y) &&
                point.x < (b.x - a.x) * (point.y - a.y) / ((b.y - a.y) == 0 ? 1e-12 : b.y - a.y) + a.x
            if intersects { inside.toggle() }
            previous = current
        }
        return inside
    }
}
