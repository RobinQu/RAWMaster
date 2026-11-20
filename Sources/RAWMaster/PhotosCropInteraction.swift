import Foundation
import CoreGraphics
import RAWMasterCore

enum PhotosCropAspect: String, CaseIterable, Identifiable {
    case original = "原始比例", freeform = "自由裁切", square = "正方形", wide = "16:9", fourFive = "4:5", fiveSeven = "5:7", fourThree = "4:3", threeFive = "3:5", threeTwo = "3:2", custom = "自定"
    var id: String { rawValue }
}
enum PhotosCropOrientation: String, CaseIterable, Identifiable {
    case landscape = "横向", portrait = "纵向"
    var id: String { rawValue }
}
struct PhotosCropConstraint: Equatable {
    var aspect: PhotosCropAspect = .freeform
    var orientation: PhotosCropOrientation = .landscape
    var customWidth = 3.0, customHeight = 2.0
    func ratio(source: DevelopmentPixelSize) throws -> Double? {
        guard customWidth.isFinite, customHeight.isFinite, (0.001...1_000_000).contains(customWidth),
              (0.001...1_000_000).contains(customHeight) else { throw EditingError.invalidRecipe }
        try source.validate()
        let value: Double
        switch aspect {
        case .freeform: return nil
        case .original: value = Double(source.width) / Double(source.height)
        case .square: return 1
        case .wide: value = 16.0 / 9
        case .fourFive: value = 4.0 / 5
        case .fiveSeven: value = 5.0 / 7
        case .fourThree: value = 4.0 / 3
        case .threeFive: value = 3.0 / 5
        case .threeTwo: value = 3.0 / 2
        case .custom: value = customWidth / customHeight
        }
        guard value.isFinite, value > 0 else { throw EditingError.invalidRecipe }
        return orientation == .landscape ? max(value, 1 / value) : min(value, 1 / value)
    }
}
enum PhotosCropHandle: String, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, center, straighten
    var left: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var right: Bool { self == .topRight || self == .right || self == .bottomRight }
    var top: Bool { self == .topLeft || self == .top || self == .topRight }
    var bottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var label: String {
        switch self {
        case .topLeft: return "左上角"; case .top: return "上边"; case .topRight: return "右上角"; case .right: return "右边"
        case .bottomRight: return "右下角"; case .bottom: return "下边"; case .bottomLeft: return "左下角"; case .left: return "左边"
        case .center: return "移动裁切框"; case .straighten: return "拖动拉直"
        }
    }
}

/// Only UI rectangle constraints. Plane dimensions are the Core continuous pre-final-crop plane,
/// never the integer bitmap/preview extent. Renderer rounding and source projection stay in Core.
enum PhotosCropInteraction {
    static func fitted(_ crop: NormalizedCrop, ratio: Double?, plane: DevelopmentContinuousRectV3) throws -> NormalizedCrop {
        try DevelopmentCropGeometryAutoV1.fitted(crop, ratio: ratio, plane: plane)
    }
    static func resized(_ start: NormalizedCrop, handle: PhotosCropHandle, delta: CGPoint,
                        plane: DevelopmentContinuousRectV3, ratio: Double?) throws -> NormalizedCrop {
        try validate(start, plane: plane)
        guard delta.x.isFinite, delta.y.isFinite else { throw EditingError.invalidRecipe }
        if delta == .zero {
            if let ratio { guard ratio.isFinite, ratio > 0 else { throw EditingError.invalidRecipe } }
            return start
        }
        if handle == .center {
            return .init(x: bounded(start.x + delta.x, 0, 1 - start.width), y: bounded(start.y + delta.y, 0, 1 - start.height), width: start.width, height: start.height)
        }
        guard handle != .straighten else { return start }
        let minW = min(1, 2 / plane.width), minH = min(1, 2 / plane.height)
        if let ratio {
            guard ratio.isFinite, ratio > 0 else { throw EditingError.invalidRecipe }
            let q = ratio * plane.height / plane.width
            let minimumH = max(minH, minW / q)
            if (handle.left || handle.right) && (handle.top || handle.bottom) {
                let anchorX = handle.left ? start.x + start.width : start.x
                let anchorY = handle.top ? start.y + start.height : start.y
                let dx = (start.width + (handle.left ? -delta.x : delta.x)) * plane.width
                let dy = (start.height + (handle.top ? -delta.y : delta.y)) * plane.height
                let projectedH = (ratio * dx + dy) / (ratio * ratio + 1) / plane.height
                let maxW = handle.left ? anchorX : 1 - anchorX, maxH = handle.top ? anchorY : 1 - anchorY
                let h = bounded(projectedH, min(minimumH, maxH, maxW / q), min(maxH, maxW / q)), w = h * q
                return .init(x: handle.left ? anchorX - w : anchorX, y: handle.top ? anchorY - h : anchorY, width: w, height: h)
            }
            if handle.left || handle.right {
                let anchorX = handle.left ? start.x + start.width : start.x, centerY = start.y + start.height / 2
                let maximumH = min(2 * min(centerY, 1 - centerY), (handle.left ? anchorX : 1 - anchorX) / q)
                let h = bounded((start.width + (handle.left ? -delta.x : delta.x)) / q, min(minimumH, maximumH), maximumH), w = h * q
                return .init(x: handle.left ? anchorX - w : anchorX, y: centerY - h / 2, width: w, height: h)
            }
            let anchorY = handle.top ? start.y + start.height : start.y, centerX = start.x + start.width / 2
            let maximumH = min(handle.top ? anchorY : 1 - anchorY, 2 * min(centerX, 1 - centerX) / q)
            let h = bounded(start.height + (handle.top ? -delta.y : delta.y), min(minimumH, maximumH), maximumH), w = h * q
            return .init(x: centerX - w / 2, y: handle.top ? anchorY - h : anchorY, width: w, height: h)
        }
        var l = start.x, t = start.y, r = start.x + start.width, b = start.y + start.height
        if handle.left { l = bounded(l + delta.x, 0, max(0, r - minW)) }
        if handle.right { r = bounded(r + delta.x, min(1, l + minW), 1) }
        if handle.top { t = bounded(t + delta.y, 0, max(0, b - minH)) }
        if handle.bottom { b = bounded(b + delta.y, min(1, t + minH), 1) }
        return .init(x: l, y: t,
            width: (handle.left || handle.right) && delta.x != 0 ? r - l : start.width,
            height: (handle.top || handle.bottom) && delta.y != 0 ? b - t : start.height)
    }
    /// Crop identity's inward-rounded raster may begin at a fractional top offset. Keep that
    /// offset when converting viewport locations to/from logical normalized crop coordinates.
    static func planePoint(_ point: CGPoint, imageRect: CGRect, plane: DevelopmentGeometryCropPlaneV3) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite, imageRect.width > 0, imageRect.height > 0 else { throw EditingError.invalidRecipe }
        return .init(x: (plane.identityRasterRect.x + (point.x - imageRect.minX) / imageRect.width * plane.identityRasterRect.width) / plane.rect.width,
                     y: (plane.identityRasterRect.y + (point.y - imageRect.minY) / imageRect.height * plane.identityRasterRect.height) / plane.rect.height)
    }
    static func screenRect(_ crop: NormalizedCrop, imageRect: CGRect, plane: DevelopmentGeometryCropPlaneV3) -> CGRect {
        .init(x: imageRect.minX + (crop.x * plane.rect.width - plane.identityRasterRect.x) / plane.identityRasterRect.width * imageRect.width,
              y: imageRect.minY + (crop.y * plane.rect.height - plane.identityRasterRect.y) / plane.identityRasterRect.height * imageRect.height,
              width: crop.width * plane.rect.width / plane.identityRasterRect.width * imageRect.width,
              height: crop.height * plane.rect.height / plane.identityRasterRect.height * imageRect.height)
    }
    static func hit(_ point: CGPoint, cropRect: CGRect, imageRect: CGRect) -> PhotosCropHandle? {
        let positions: [(PhotosCropHandle, CGPoint)] = [(.topLeft,.init(x:cropRect.minX,y:cropRect.minY)),(.topRight,.init(x:cropRect.maxX,y:cropRect.minY)),
            (.bottomLeft,.init(x:cropRect.minX,y:cropRect.maxY)),(.bottomRight,.init(x:cropRect.maxX,y:cropRect.maxY)),(.left,.init(x:cropRect.minX,y:cropRect.midY)),
            (.right,.init(x:cropRect.maxX,y:cropRect.midY)),(.top,.init(x:cropRect.midX,y:cropRect.minY)),(.bottom,.init(x:cropRect.midX,y:cropRect.maxY))]
        if let result = positions.min(by: { hypot(point.x-$0.1.x,point.y-$0.1.y) < hypot(point.x-$1.1.x,point.y-$1.1.y) }),
           hypot(point.x-result.1.x,point.y-result.1.y) <= 9 { return result.0 }
        if cropRect.contains(point) { return .center }
        if imageRect.insetBy(dx:-20,dy:-20).contains(point) { return .straighten }
        return nil
    }
    private static func validate(_ crop: NormalizedCrop, plane: DevelopmentContinuousRectV3) throws {
        guard [plane.width,plane.height,crop.x,crop.y,crop.width,crop.height].allSatisfy(\.isFinite), plane.width > 0, plane.height > 0,
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0, crop.x + crop.width <= 1 + 1e-12,
              crop.y + crop.height <= 1 + 1e-12 else { throw EditingError.invalidRecipe }
    }
    private static func bounded(_ value: Double, _ lower: Double, _ upper: Double) -> Double { max(lower, min(upper, value)) }
}
