import Foundation
import simd

// This contract describes numeric RGB, not a Core Graphics tag or an output rendering.
enum DevelopmentSceneColorV1 {
  static let operatorVersion = "scene-color-v1/ocio-studio-v4-aces2/matrix-exposure-premul-f32"
  static let referenceConfigSHA256 = "3a48b0421e51d4284ec07187f86b74387321550b65f5a2f237885bf269dbc99e"

  enum Space: String, Hashable {
    case linearRec709, aces2065, acescg
  }

  enum Reference: Hashable {
    case sceneLinear(scaleToSceneReference: Float)
    case displayLinear
  }

  enum Alpha: Hashable {
    case straight, premultiplied
  }

  struct Port: Hashable {
    let space: Space
    let reference: Reference
    let alpha: Alpha

    static let working = Port(space: .acescg, reference: .sceneLinear(scaleToSceneReference: 1), alpha: .premultiplied)
    static let exchange = Port(space: .aces2065, reference: .sceneLinear(scaleToSceneReference: 1), alpha: .premultiplied)
  }

  enum Failure: Error, Equatable {
    case displayReferredInput, invalidScale, unsupportedConversion, invalidPixel, invalidRegion, invalidTexture
    case metalUnavailable, gpuExecutionFailed
  }

  struct Transform {
    let rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    let scale: Float
    let input: Port
    let output: Port

    fileprivate init(rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>), scale: Float, input: Port, output: Port) {
      self.rows = rows; self.scale = scale; self.input = input; self.output = output
    }

    func apply(_ pixel: SIMD4<Float>) throws -> SIMD4<Float> {
      guard pixel.x.isFinite, pixel.y.isFinite, pixel.z.isFinite,
            pixel.w.isFinite, (0...1).contains(pixel.w) else { throw Failure.invalidPixel }
      if pixel.w == 0 { return .zero }
      let rgb = SIMD4(pixel.x, pixel.y, pixel.z, 0) * (input.alpha == .straight ? pixel.w : 1)
      let value = SIMD3(simd_dot(rows.0, rgb), simd_dot(rows.1, rgb), simd_dot(rows.2, rgb)) * scale
      guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { throw Failure.invalidPixel }
      return SIMD4(value, pixel.w)
    }
  }

  static func makeTransform(from input: Port, to target: Space = .acescg, exposureEV: Float = 0) throws -> Transform {
    guard case .sceneLinear(let normalization) = input.reference else { throw Failure.displayReferredInput }
    guard normalization.isFinite, normalization > 0, exposureEV.isFinite else { throw Failure.invalidScale }
    let scale = Float(Double(normalization) * exp2(Double(exposureEV)))
    guard scale.isFinite, scale >= Float.leastNormalMagnitude else { throw Failure.invalidScale }
    let rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    switch (input.space, target) {
    case (.linearRec709, .acescg):
      rows = (.init(0.61309740, 0.33952315, 0.04737945, 0),
              .init(0.07019372, 0.91635388, 0.01345240, 0),
              .init(0.02061559, 0.10956977, 0.86981463, 0))
    case (.aces2065, .acescg):
      rows = (.init(1.4514393161, -0.2365107469, -0.2149285693, 0),
              .init(-0.0765537734, 1.1762296998, -0.0996759264, 0),
              .init(0.0083161484, -0.0060324498, 0.9977163014, 0))
    case (.acescg, .aces2065):
      rows = (.init(0.6954522414, 0.1406786965, 0.1638690622, 0),
              .init(0.0447945634, 0.8596711185, 0.0955343182, 0),
              .init(-0.0055258826, 0.0040252103, 1.0015006723, 0))
    case (.acescg, .acescg), (.aces2065, .aces2065):
      rows = (.init(1, 0, 0, 0), .init(0, 1, 0, 0), .init(0, 0, 1, 0))
    default: throw Failure.unsupportedConversion
    }
    return Transform(rows: rows, scale: scale, input: input, output: target == .acescg ? .working : .exchange)
  }
}
