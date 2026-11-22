import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import RAWMasterCore
import RAWMasterPhotoExport

public enum BuiltinPhotoStyle: String, CaseIterable, Codable, Sendable {
    case plain, paper, mist, sign, split, date
}

public enum PhotoExportMetadataPolicy: String, CaseIterable, Codable, Sendable {
    case none, rights, photo
}

/// The labels painted onto one photograph. Missing capture fields stay empty.
public struct PhotoExportMetadata: Equatable, Sendable {
    public var camera, lens, focalLength, aperture, shutter, iso, date: String?

    public init(camera: String? = nil, lens: String? = nil, focalLength: String? = nil,
                aperture: String? = nil, shutter: String? = nil, iso: String? = nil,
                date: String? = nil) {
        self.camera = camera; self.lens = lens; self.focalLength = focalLength
        self.aperture = aperture; self.shutter = shutter; self.iso = iso; self.date = date
    }

    public static func read(from url: URL) -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return .init() }
        return from(source)
    }

    static func from(_ source: CGImageSource) -> Self {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .init() }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func positive(_ value: Any?) -> Double? {
            guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n > 0 else { return nil }
            return n
        }
        func decimal(_ number: Double) -> String {
            number.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(0...2)))
        }
        let rawISO = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first
            ?? exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber
        let time = positive(exif[kCGImagePropertyExifExposureTime]).map { seconds in
            seconds < 0.5 ? "1/\(decimal((1 / seconds).rounded())) s" : "\(decimal(seconds)) s"
        }
        let captureDate = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap { value -> String? in
            let day = String(value.prefix(10)).replacingOccurrences(of: ":", with: "-")
            guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
            return day
        }
        return .init(camera: tiff[kCGImagePropertyTIFFModel] as? String,
                     lens: (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String,
                     focalLength: positive(exif[kCGImagePropertyExifFocalLength]).map { "\(decimal($0)) mm" },
                     aperture: positive(exif[kCGImagePropertyExifFNumber]).map { "ƒ/\(decimal($0))" },
                     shutter: time, iso: positive(rawISO).map { "ISO \(decimal($0))" }, date: captureDate)
    }

    fileprivate func value(for field: String) -> String? {
        switch field {
        case "camera": return camera
        case "lens": return lens
        case "focal": return focalLength
        case "aperture": return aperture
        case "shutter": return shutter
        case "iso": return iso
        case "date": return date
        default: return nil
        }
    }
}

/// Portable fields used by .rmexport.json. All positions use final-canvas coordinates.
public struct PhotoExportAppearance: Codable, Equatable, Sendable {
    public struct Logo: Codable, Equatable, Sendable {
        public var mime, sha256, base64: String
        public init(mime: String = "image/png", sha256: String, base64: String) {
            self.mime = mime; self.sha256 = sha256; self.base64 = base64
        }

        fileprivate func image() throws -> CIImage {
            guard mime == "image/png", !base64.isEmpty, base64.utf8.count <= 1_500_000,
                  let data = Data(base64Encoded: base64), data.starts(with: [137,80,78,71,13,10,26,10]),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
                  (1...512).contains(w), (1...512).contains(h), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw EditingError.invalidRecipe }
            return CIImage(cgImage: cg)
        }
    }

    public var builtin: BuiltinPhotoStyle
    public var frame = "none", ratio = "source", fit = "contain", paper = "#f6f1e7"
    public var margin = 5, stroke = 0, strokeColor = "#575653", shadow = false
    public var mark = "off", place = "photo", anchor = "br", signature: String
    public var fields = ["camera", "focal", "aperture", "shutter", "iso"]
    public var font = "sans", ink = "#ffffff", opacity = 95, scale = 100
    public var logo: Logo?

    public init(style: BuiltinPhotoStyle, signature: String = "") {
        builtin = style; self.signature = signature
        let caption = signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "exif" : "both"
        switch style {
        case .plain: break
        case .paper:
            frame = "solid"; ratio = "3:2"; stroke = 1; mark = caption; place = "footer"
            anchor = "bc"; font = "serif"; ink = "#282823"
        case .mist:
            frame = "blur"; ratio = "4:5"; shadow = true; mark = "exif"; place = "footer"; anchor = "bc"
        case .sign:
            mark = "signature"; font = "serif"; opacity = 78
        case .split:
            frame = "solid"; paper = "#ffffff"; margin = 0; mark = caption; place = "footer"; anchor = "bl"
            ink = "#242424"; fields = ["camera", "lens", "focal", "aperture", "shutter", "iso", "date"]
        case .date:
            mark = "exif"; fields = ["date"]; font = "mono"; ink = "#f4a75d"; opacity = 90; scale = 120
        }
    }

    fileprivate var drawsEXIF: Bool { mark == "both" || mark == "exif" }
    fileprivate var drawsSignature: Bool { mark == "both" || mark == "signature" }

    public func validate() throws {
        let fieldSet: Set<String> = ["camera", "lens", "focal", "aperture", "shutter", "iso", "date"]
        guard ["none", "solid", "blur"].contains(frame), ["contain", "cover"].contains(fit),
              ["source","1:1","4:5","3:2","16:9"].contains(ratio), ["photo","footer"].contains(place),
              ["off","signature","exif","both","logo"].contains(mark), ["sans","serif","mono"].contains(font),
              ["tl","tc","tr","cl","cc","cr","bl","bc","br"].contains(anchor),
              (0...16).contains(margin), (0...5).contains(stroke), (60...160).contains(scale), (0...100).contains(opacity),
              [paper, strokeColor, ink].allSatisfy({ PhotoExportLayout.rgb($0) != nil }),
              signature.utf16.count <= 100, Set(fields).isSubset(of: fieldSet),
              Set(fields).count == fields.count, frame != "none" || place == "photo",
              place != "footer" || anchor.first == "b" else { throw EditingError.invalidRecipe }
    }
}

public struct PhotoExportLayout: Equatable, Codable, Sendable {
    public var style: BuiltinPhotoStyle
    public var signature: String
    public var inkHex: String?
    public var opacity: Double
    public var appearance: PhotoExportAppearance?

    public init(style: BuiltinPhotoStyle = .plain, signature: String? = nil, inkHex: String? = nil, opacity: Double? = nil,
                appearance: PhotoExportAppearance? = nil) {
        self.style = appearance?.builtin ?? style
        let defaults = appearance ?? .init(style: style)
        self.signature = signature ?? defaults.signature; self.inkHex = inkHex
        self.opacity = opacity ?? Double(defaults.opacity) / 100
        self.appearance = appearance
    }

    /// Includes the editor's three simple controls so a portable preset can take the exact same values.
    public var resolvedAppearance: PhotoExportAppearance {
        var look = appearance ?? .init(style: style, signature: signature)
        look.signature = signature
        if let inkHex { look.ink = inkHex }
        if opacity.isFinite, (0...1).contains(opacity) { look.opacity = Int((opacity * 100).rounded()) }
        return look
    }

    public func validate() throws {
        guard opacity.isFinite, (0...1).contains(opacity) else { throw EditingError.invalidRecipe }
        try resolvedAppearance.validate()
    }

    private struct Geometry {
        var canvas, photo, footer: CGRect
    }

    private func geometry(_ size: CGSize, limit: Int?) -> Geometry? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 100_000, size.height <= 100_000 else { return nil }
        let look = resolvedAppearance
        let ratios: [String: [UInt32]] = ["1:1": [1, 1], "3:2": [3, 2], "4:5": [4, 5], "16:9": [16, 9]]
        let footerScale = look.mark == "off" || look.place != "footer" ? 0 : (look.builtin == .split ? 150 : 120)
        let frame = look.frame == "none" ? nil : PhotoExportKernel.Frame(
            ratio: ratios[look.ratio], marginPercent: look.margin,
            footerPerMille: (footerScale * look.scale + 50) / 100, cover: look.fit == "cover")
        let source = PhotoExportKernel.Dimensions(width: UInt32(size.width.rounded()), height: UInt32(size.height.rounded()))
        guard let plan = try? PhotoExportKernel.geometry(source: source, longEdge: limit, frame: frame) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: Int(plan.canvas.width), height: Int(plan.canvas.height))
        func flipped(_ region: PhotoExportKernel.Region) -> CGRect {
            CGRect(x: Int(region.x), y: Int(plan.canvas.height - region.y - region.height),
                   width: Int(region.width), height: Int(region.height))
        }
        return Geometry(canvas: canvas, photo: flipped(plan.photo), footer: flipped(plan.footer))
    }

    public func pixelSize(for photoSize: CGSize, maximumLongEdge: Int? = nil) -> CGSize {
        geometry(photoSize, limit: maximumLongEdge)?.canvas.size ?? .zero
    }

    public func render(_ image: CIImage, metadata: PhotoExportMetadata = .init(),
                       maximumLongEdge: Int? = nil) throws -> CIImage {
        try validate()
        let extent = image.extent, look = resolvedAppearance
        guard !extent.isInfinite, extent.minX.isFinite, extent.minY.isFinite,
              let geo = geometry(extent.size, limit: maximumLongEdge) else { throw DevelopmentError.invalidGeometry }
        let source = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)).settingProperties([:])
        let canvas = geo.canvas, short = min(canvas.width, canvas.height)
        let photo = Self.fitted(source, in: geo.photo, cover: true)
        var result = photo
        if look.frame != "none" {
            var base = look.frame == "blur" ? Self.mistBackground(source, canvas: canvas)
                : CIImage(color: Self.color(look.paper)).cropped(to: canvas)
            if look.shadow {
                let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.38)).cropped(to: geo.photo)
                    .transformed(by: .init(translationX: 0, y: -short * 0.008))
                    .applyingGaussianBlur(sigma: Double(short * 0.012))
                base = shadow.composited(over: base)
            }
            result = photo.composited(over: base)
            if look.stroke > 0 {
                let r = geo.photo, line = min(r.width / 2, r.height / 2, short * CGFloat(look.stroke) / 1000)
                let edges = [CGRect(x:r.minX,y:r.minY,width:line,height:r.height), CGRect(x:r.maxX-line,y:r.minY,width:line,height:r.height),
                             CGRect(x:r.minX,y:r.minY,width:r.width,height:line), CGRect(x:r.minX,y:r.maxY-line,width:r.width,height:line)]
                for edge in edges { result = CIImage(color: Self.color(look.strokeColor)).cropped(to: edge).composited(over: result) }
            }
        }
        guard look.mark != "off", opacity > 0 else { return result.cropped(to: canvas) }
        let logo = try look.logo?.image()
        if look.mark == "logo", logo == nil { throw EditingError.invalidRecipe }
        let available = look.drawsEXIF ? Dictionary(uniqueKeysWithValues: look.fields.compactMap { key in
            metadata.value(for: key).flatMap { $0.isEmpty ? nil : (key, $0) }
        }) : [:]
        let title = look.drawsSignature ? signature.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let srgb = Self.rgb(look.ink)!
        let ink = CGColor(srgbRed: srgb.0, green: srgb.1, blue: srgb.2, alpha: opacity)
        if look.builtin == .split, geo.footer.height > 0, look.drawsEXIF {
            result = try splitCaption(on: result, area: geo.footer, look: look, title: title, values: available, logo: logo, ink: ink)
        } else {
            let footer = look.place == "footer" && geo.footer.height > 0
            let area = footer ? geo.footer : geo.photo
            result = try caption(on: result, area: area, footer: footer, short: short, look: look, title: title,
                                 fields: look.fields.compactMap { available[$0] }, logo: logo, ink: ink)
        }
        return result.cropped(to: canvas)
    }

    private struct CaptionRow {
        var text: String
        var font: String
        var size: CGFloat
        var width: CGFloat
    }

    private func caption(on image: CIImage, area: CGRect, footer: Bool, short: CGFloat, look: PhotoExportAppearance,
                         title: String, fields: [String], logo: CIImage?, ink: CGColor) throws -> CIImage {
        let inset = min(area.width * 0.08, area.height * 0.12, short * (footer ? 0.012 : 0.028))
        let usable = max(1, area.width - 2 * inset)
        let unit = min(short * 0.032 * CGFloat(look.scale) / 100, area.height * (footer ? 0.31 : 0.16))
        let logoSize = Self.logoSize(logo, maxWidth: usable * 0.25, maxHeight: min(unit * 1.9, area.height - 2 * inset))
        let gap = logoSize.width > 0 && (!title.isEmpty || !fields.isEmpty) ? unit * 0.48 : 0
        let width = max(1, usable - logoSize.width - gap)
        var rows: [CaptionRow] = []
        func add(_ value: String, size: CGFloat, bold: Bool) {
            let font = Self.font(look.font, bold: bold)
            let measured = Self.textWidth(value, font: font, size: size)
            let fitted = min(1, width / max(1, measured))
            rows.append(.init(text: value, font: font, size: size * fitted, width: measured * fitted))
        }
        if !title.isEmpty { add(title, size: unit, bold: true) }
        let fontSize = unit * (title.isEmpty ? 0.79 : 0.60), family = Self.font(look.font, bold: false)
        var line = ""
        for field in fields {
            let next = line.isEmpty ? field : line + "  ·  " + field
            if !line.isEmpty && Self.textWidth(next, font: family, size: fontSize) > width {
                add(line, size: fontSize, bold: false); line = field
            } else { line = next }
        }
        if !line.isEmpty { add(line, size: fontSize, bold: false) }
        let desiredHeight = rows.reduce(CGFloat.zero) { $0 + $1.size * 1.35 }
        let fit = min(1, max(1, area.height - 2 * inset) / max(1, desiredHeight))
        let textHeight = desiredHeight * fit, textWidth = (rows.map(\.width).max() ?? 0) * fit
        let groupW = logoSize.width + gap + textWidth, groupH = max(logoSize.height, textHeight)
        let a = look.anchor.last, v = footer ? Character("c") : look.anchor.first
        let x = a == "l" ? area.minX + inset : a == "r" ? area.maxX - inset - groupW : area.midX - groupW / 2
        let y = v == "b" ? area.minY + inset : v == "t" ? area.maxY - inset - groupH : area.midY - groupH / 2
        let logoBox = CGRect(x: x, y: y + (groupH - logoSize.height) / 2, width: logoSize.width, height: logoSize.height)
        var result = Self.paintLogo(logo, in: logoBox, opacity: opacity, over: image)
        var top = y + (groupH + textHeight) / 2
        for row in rows {
            let h = row.size * fit * 1.35
            let box = CGRect(x: x + logoSize.width + gap, y: top - h, width: textWidth, height: h)
            result = try Self.draw(row.text, font: row.font, size: row.size * fit, color: ink, box: box,
                                   align: a == "l" ? .left : a == "r" ? .right : .center, on: result)
            top -= h
        }
        return result
    }

    private func splitCaption(on image: CIImage, area: CGRect, look: PhotoExportAppearance, title: String,
                              values: [String: String], logo: CIImage?, ink: CGColor) throws -> CIImage {
        let pad = max(1, min(area.width * 0.045, area.height * 0.29))
        let size = min(area.height * 0.25, area.width * 0.037) * CGFloat(look.scale) / 100
        let split = area.minX + area.width * 0.49
        let logoSize = Self.logoSize(logo, maxWidth: area.width * 0.13, maxHeight: min(size * 1.65, area.height * 0.55))
        let logoBox = CGRect(x: area.minX + pad, y: area.midY - logoSize.height/2, width: logoSize.width, height: logoSize.height)
        var result = Self.paintLogo(logo, in: logoBox, opacity: opacity, over: image)
        let leftX = area.minX + pad + (logoSize.width > 0 ? logoSize.width + pad * 0.45 : 0)
        let left = [values["camera"] ?? title,
                    [values["lens"], values["camera"] == nil ? nil : title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")]
        let right = [["focal","aperture","shutter","iso"].compactMap { values[$0] }.joined(separator: "  "), values["date"] ?? ""]
        func column(_ texts: [String], x: CGFloat, width: CGFloat, align: Alignment) throws {
            let present = texts.filter { !$0.isEmpty }
            for (index, value) in present.enumerated() {
                let cy = area.minY + area.height * (present.count == 1 ? 0.50 : index == 0 ? 0.64 : 0.31)
                let box = CGRect(x: x, y: cy - area.height * 0.15, width: max(1, width), height: area.height * 0.30)
                result = try Self.draw(value, font: Self.font(look.font, bold: index == 0),
                    size: size * (index == 0 ? 1 : 0.76), color: ink, box: box, align: align, on: result)
            }
        }
        try column(left, x: leftX, width: split - pad - leftX, align: .left)
        try column(right, x: split + pad, width: area.maxX - split - 2 * pad, align: .right)
        if left.contains(where: { !$0.isEmpty }) && right.contains(where: { !$0.isEmpty }) {
            let rule = CGRect(x: split, y: area.minY + area.height*0.25, width: max(1, area.width/1500), height: area.height*0.5)
            result = CIImage(color: Self.color(look.ink, opacity: opacity * 0.38)).cropped(to: rule).composited(over: result)
        }
        return result
    }

    private static func color(_ hex: String, opacity: Double = 1) -> CIColor {
        let c = rgb(hex)!
        return CIColor(cgColor: CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: opacity))
    }

    private static func font(_ family: String, bold: Bool) -> String {
        switch family {
        case "serif": return bold ? "Georgia-Bold" : "Georgia"
        case "mono": return bold ? "Menlo-Bold" : "Menlo"
        default: return bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
        }
    }

    private static func textWidth(_ text: String, font: String, size: CGFloat) -> CGFloat {
        let face = CTFontCreateWithName(font as CFString, max(0.1, size), nil)
        let attr = NSAttributedString(string: String(text.prefix(500)), attributes: [.init(kCTFontAttributeName as String): face])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    }

    private static func logoSize(_ logo: CIImage?, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard let logo, maxHeight > 0, maxWidth > 0 else { return .zero }
        let factor = min(maxWidth / logo.extent.width, maxHeight / logo.extent.height)
        return CGSize(width: logo.extent.width * factor, height: logo.extent.height * factor)
    }

    private static func paintLogo(_ logo: CIImage?, in box: CGRect, opacity: Double, over image: CIImage) -> CIImage {
        guard let logo, !box.isEmpty else { return image }
        let placed = logo.transformed(by: .init(scaleX: box.width / logo.extent.width, y: box.height / logo.extent.height))
            .transformed(by: .init(translationX: box.minX, y: box.minY))
        let faded = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        return faded.composited(over: image)
    }

    private static func fitted(_ source: CIImage, in box: CGRect, cover: Bool = false) -> CIImage {
        let sx = box.width / source.extent.width, sy = box.height / source.extent.height
        let scale = cover ? max(sx, sy) : min(sx, sy)
        let size = CGSize(width: max(1, (source.extent.width * scale).rounded()),
                          height: max(1, (source.extent.height * scale).rounded()))
        let target = CGRect(x: box.minX + ((box.width - size.width) / 2).rounded(.down),
                            y: box.minY + ((box.height - size.height) / 2).rounded(.down),
                            width: size.width, height: size.height)
        let photo = source.samplingLinear().transformed(by: .init(scaleX: size.width / source.extent.width,
                                                                   y: size.height / source.extent.height))
            .transformed(by: .init(translationX: target.minX, y: target.minY))
        return photo.cropped(to: cover ? box : target)
    }

    private static func mistBackground(_ source: CIImage, canvas: CGRect) -> CIImage {
        // A soft backdrop has no fine detail. Compute its blur at bounded resolution even for tiled prints.
        let factor = min(1, 640 / max(canvas.width, canvas.height))
        let small = CGRect(x: 0, y: 0, width: max(1, (canvas.width * factor).rounded()),
                           height: max(1, (canvas.height * factor).rounded()))
        let blur = fitted(source, in: small, cover: true).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(min(small.width, small.height) * 0.033)).cropped(to: small)
        let backdrop = blur.transformed(by: .init(scaleX: canvas.width / small.width, y: canvas.height / small.height))
        let shade = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.36)).cropped(to: canvas)
        return shade.composited(over: backdrop)
    }

    fileprivate static func rgb(_ text: String) -> (CGFloat, CGFloat, CGFloat)? {
        guard text.utf8.count == 7, text.first == "#", text.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return (CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }

    private enum Alignment { case left, center, right }

    /// Rasterize only the glyph layer. The underlying photographic pixels stay in the CI working space.
    private static func draw(_ text: String, font name: String, size: CGFloat, color: CGColor,
                             box: CGRect, align: Alignment, on image: CIImage) throws -> CIImage {
        guard size > 0, box.width > 0, box.height > 0, !text.isEmpty, color.alpha > 0 else { return image }
        let fontSize = min(256, max(36, size))
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: String(text.prefix(500)), attributes: [
            .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).insetBy(dx: -1, dy: -1)
        guard bounds.width > 2, bounds.height > 2 else { return image }
        let scale = min(size / fontSize, box.width / bounds.width, box.height / bounds.height)
        let rasterScale = min(1, 8192 / bounds.width)
        let w = max(1, Int(ceil(bounds.width * rasterScale))), h = max(1, Int(ceil(bounds.height * rasterScale)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw DevelopmentError.invalidEncoding }
        bitmap.scaleBy(x: rasterScale, y: rasterScale)
        bitmap.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
        CTLineDraw(line, bitmap)
        guard let cg = bitmap.makeImage() else { throw DevelopmentError.invalidEncoding }
        let rendered = CIImage(cgImage: cg).transformed(by: .init(scaleX: scale / rasterScale, y: scale / rasterScale))
        let x: CGFloat
        switch align {
        case .left: x = box.minX
        case .center: x = box.midX - rendered.extent.width / 2
        case .right: x = box.maxX - rendered.extent.width
        }
        return rendered.transformed(by: .init(translationX: x, y: box.midY - rendered.extent.height / 2))
            .cropped(to: box).composited(over: image)
    }
}
