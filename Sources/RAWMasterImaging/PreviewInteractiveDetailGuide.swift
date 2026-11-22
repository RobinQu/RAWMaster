import CoreImage
import Metal
import RAWMasterCore

/// These single-control edits can reuse an immutable neighbourhood measured on the
/// verified FlashRaw proxy. Combined recipes continue through the full ordered graph.
enum PreviewInteractiveDetailGuide {
  case lumaNoise(radius: Double)
  case sharpen(radius: Double)
  case band(DevelopmentAdvancedDetailEngineV3.Band, amount: Double, radius: Double)

  static func isPureSharpen(_ recipe: DevelopmentAdjustmentsV3,maskPreview:Bool = false) -> Bool {
    guard recipe.rawDecoder == .flashRaw031, recipe.aiDenoise == nil,
          recipe.sharpen.enabled else { return false }
    let visualization = recipe.sharpen.visualiseMasking == true
    guard maskPreview ? visualization : (!visualization && recipe.sharpen.intensity != 0) else { return false }
    var neutral=recipe.neutralForSameSource
    neutral.rawDetails=recipe.rawDetails
    neutral.sharpen=recipe.sharpen
    return recipe == neutral
  }

  init?(_ recipe: DevelopmentAdjustmentsV3, size: DevelopmentPixelSize, scale: Double = 1) throws {
    guard recipe.rawDecoder == .flashRaw031, recipe.aiDenoise == nil else { return nil }
    let noise = recipe.noiseReduction
    if noise.enabled, noise.colorNoise == 0, (noise.luminanceContrast ?? 0) == 0, (noise.colorDetail ?? 0) == 0,
       noise.luminanceNoise != 0 || noise.detail != 0, FlashRawNoiseReduction.hasLumaKernels {
      var neutral = recipe.neutralForSameSource
      neutral.rawDetails = recipe.rawDetails
      neutral.noiseReduction = noise
      if recipe == neutral {
        try noise.validate(for:.raw)
        self = .lumaNoise(radius:1.5*scale)
        return
      }
    }
    let bands = recipe.advancedDetail
    let sharpen = recipe.sharpen.enabled && recipe.sharpen.intensity != 0 && recipe.sharpen.visualiseMasking != true
    guard sharpen || (bands.texture.enabled && bands.texture.amount != 0) || (bands.clarity.enabled && bands.clarity.amount != 0) else { return nil }
    if sharpen {
      guard Self.isPureSharpen(recipe) else { return nil }
      self = .sharpen(radius:recipe.sharpen.radius ?? DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff:recipe.sharpen.falloff))
      return
    }
    // The canonical portrait implementation normalizes its Gaussian pass order.
    guard size.width >= size.height else { return nil }
    var neutral = recipe.neutralForSameSource
    neutral.rawDetails = recipe.rawDetails
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:size)
    if bands.texture.enabled, bands.texture.amount != 0 {
      neutral.advancedDetail.texture = bands.texture
      self = .band(.texture,amount:bands.texture.amount,radius:radii.texture)
    } else if bands.clarity.enabled, bands.clarity.amount != 0 {
      neutral.advancedDetail.clarity = bands.clarity
      self = .band(.clarity,amount:bands.clarity.amount,radius:radii.clarity)
    } else { return nil }
    guard recipe == neutral, DevelopmentAdvancedDetailEngineV3.hasCachedBandKernels else { return nil }
  }

  var identity: String {
    switch self {
    case let .lumaNoise(radius): return "raw-noise-luma-residual-v1/" + String(radius.bitPattern,radix:16)
    case let .sharpen(radius): return "sharpen-luma/" + String(radius.bitPattern,radix:16)
    case let .band(_,_,radius): return "log-band/" + String(radius.bitPattern,radix:16)
    }
  }

  func factor(for image: CIImage) throws -> CIImage {
    switch self {
    case let .lumaNoise(radius): return try FlashRawNoiseReduction.measureLuma(image,radius:radius)
    case let .sharpen(radius): return try DevelopmentGlobalEngineV3.sharpeningMean(image,radius:radius)
    case let .band(_,_,radius): return try DevelopmentAdvancedDetailEngineV3.bandFactor(image,radius:radius)
    }
  }

  func render(_ recipe: DevelopmentAdjustmentsV3, source: CIImage, guide: CIImage) throws -> CIImage {
    switch self {
    case .lumaNoise: return try FlashRawNoiseReduction.applyLuma(recipe.noiseReduction,to:source,guide:guide)
    case .sharpen: return try DevelopmentGlobalEngineV3.apply(recipe,to:source,sourceIsRAW:true,preparedSharpMean:guide)
    case let .band(band,amount,_): return try DevelopmentAdvancedDetailEngineV3.applyBand(band,amount:amount,to:source,factor:guide)
    }
  }
}
