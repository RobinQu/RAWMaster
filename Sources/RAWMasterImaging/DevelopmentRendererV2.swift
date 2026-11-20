import CoreImage
import ImageIO
import RAWMasterCore

extension PhotoRenderer {
  static func renderingContext(_ recipe: DevelopmentRecipe) -> CIContext {
    if recipe.schemaVersion == 3 {
      if let legacy = try? DevelopmentRendererV3.legacyEquivalent(recipe) { return renderingContext(legacy) }
      return DevelopmentColorEngineV3.context
    }
    return recipe.schemaVersion == 2 && recipe.color?.isNeutral == false ? DevelopmentColorEngineV2.context : context
  }
  static func developV2(_ url: URL, _ recipe: DevelopmentRecipe) throws -> (CIImage, Int?) {
    try recipe.validate()
    guard let color = recipe.color, recipe.engineVersion == "rawmaster-color-v2" else { throw DevelopmentError.unsupportedEngine }
    if color.isNeutral {
      var legacy = recipe; legacy.schemaVersion = 1; legacy.engineVersion = "core-image-v1"; legacy.color = nil
      return try develop(url, legacy)
    }
    var image: CIImage
    var sourceDepth: Int?
    if rawExtensions.contains(url.pathExtension.lowercased()) {
      guard let raw = CIRAWFilter(imageURL: url) else { throw DevelopmentError.unreadable }
      raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = Float(recipe.exposureEV)
      if case let .temperatureTint(temperature, tint) = recipe.whiteBalance { raw.neutralTemperature = Float(temperature); raw.neutralTint = Float(tint) }
      guard let output = raw.outputImage else { throw DevelopmentError.unreadable }
      // CIRAWFilter applies EXIF orientation. Do not apply it a second time.
      image = output
    } else {
      guard let output = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DevelopmentError.unreadable }
      image = output; sourceDepth = cg.bitsPerComponent
      if case let .temperatureTint(temperature, tint) = recipe.whiteBalance {
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: temperature, y: tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
      }
      if recipe.exposureEV != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposureEV]) }
    }
    image = try DevelopmentColorEngineV2.apply(color, to: image)
    try DevelopmentColorEngineV2.validateFinite(image)
    return (try applyV2Geometry(image, recipe), sourceDepth)
  }
  static func applyV2Geometry(_ input: CIImage, _ recipe: DevelopmentRecipe) throws -> CIImage {
    var image = input
    guard !image.extent.isEmpty, !image.extent.isInfinite else { throw DevelopmentError.unreadable }
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    if recipe.straightenDegrees != 0 {
      let w = image.extent.width, h = image.extent.height
      let angle = recipe.straightenDegrees * .pi / 180
      image = image.transformed(by: CGAffineTransform(translationX: -w/2, y: -h/2))
        .transformed(by: CGAffineTransform(rotationAngle: angle))
      let size = inscribedSize(width: w, height: h, angle: abs(angle))
      image = image.cropped(to: CGRect(x: -size.width/2, y: -size.height/2, width: size.width, height: size.height))
      image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    let bounds = image.extent, crop = recipe.crop
    let rect = CGRect(x: bounds.width * crop.x, y: bounds.height * (1 - crop.y - crop.height), width: bounds.width * crop.width, height: bounds.height * crop.height)
    // Round inward so fractional crop/rotation bounds cannot add a transparent border.
    let pixels = CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: floor(rect.maxX) - ceil(rect.minX), height: floor(rect.maxY) - ceil(rect.minY))
    guard pixels.width >= 1, pixels.height >= 1 else { throw DevelopmentError.invalidGeometry }
    image = image.cropped(to: pixels).transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
    return image
  }
}
