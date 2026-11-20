import CoreImage
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

// Test-only source clone of the approved developV2. The sole processing change is an injected
// finite-validation context. Decoder, color kernel and geometry are ACTUAL production functions.
enum ContextProbeV2Clone {
  static func develop(_ url: URL, _ recipe: DevelopmentRecipe, context: CIContext) throws -> (CIImage, Int?) {
    try recipe.validate()
    guard let color = recipe.color, recipe.engineVersion == "rawmaster-color-v2" else { throw DevelopmentError.unsupportedEngine }
    if color.isNeutral {
      var legacy = recipe; legacy.schemaVersion = 1; legacy.engineVersion = "core-image-v1"; legacy.color = nil
      return try PhotoRenderer.develop(url, legacy)
    }
    var image: CIImage
    var sourceDepth: Int?
    if PhotoRenderer.rawExtensions.contains(url.pathExtension.lowercased()) {
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
    try DevelopmentColorEngineV2.validateFinite(image, context: context)
    return (try PhotoRenderer.applyV2Geometry(image, recipe), sourceDepth)
  }
}
