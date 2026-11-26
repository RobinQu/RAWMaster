import simd

struct DevelopmentCameraCalibrationV1 {
  enum Failure: Error, Equatable {
    case invalidCalibration, invalidGeometry, invalidMosaic, unqualifiedSource
  }

  let rows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

  init(xyzToCamera coefficients: [Float], whiteBalance: SIMD4<Float>) throws {
    guard coefficients.count == 9, coefficients.allSatisfy(\.isFinite),
          (0..<4).allSatisfy({ whiteBalance[$0].isFinite && whiteBalance[$0] > 0 }),
          abs(whiteBalance.y - whiteBalance.w) <= 1e-5 * whiteBalance.y else { throw Failure.invalidCalibration }
    func inputRow(_ i: Int) -> SIMD3<Double> {
      .init(Double(coefficients[i]), Double(coefficients[i+1]), Double(coefficients[i+2]))
    }
    let matrix = simd_double3x3(rows: [inputRow(0), inputRow(3), inputRow(6)])
    guard abs(simd_determinant(matrix)) > 1e-8 else { throw Failure.invalidCalibration }
    let cameraToXYZ = matrix.inverse
    let cameraNeutral = SIMD3<Double>(Double(whiteBalance.y) / Double(whiteBalance.x),
      1, Double(whiteBalance.y) / Double(whiteBalance.z))
    let sourceWhite = cameraToXYZ * cameraNeutral
    guard (0..<3).allSatisfy({ sourceWhite[$0].isFinite && sourceWhite[$0] > 0 }) else { throw Failure.invalidCalibration }

    let cat = simd_double3x3(rows: [SIMD3(0.8951, 0.2664, -0.1614),
      SIMD3(-0.7502, 1.7135, 0.0367), SIMD3(0.0389, -0.0685, 1.0296)])
    let acesWhite = SIMD3(0.32168 / 0.33767, 1, (1 - 0.32168 - 0.33767) / 0.33767)
    let sourceCone = cat * (sourceWhite / sourceWhite.y)
    guard (0..<3).allSatisfy({ sourceCone[$0].isFinite && sourceCone[$0] > 1e-8 }) else { throw Failure.invalidCalibration }
    let adaptation = cat.inverse * simd_double3x3(diagonal: (cat * acesWhite) / sourceCone) * cat
    let xyzToAP1 = simd_double3x3(rows: [SIMD3(1.6410233797, -0.3248032942, -0.2364246952),
      SIMD3(-0.6636628587, 1.6153315917, 0.0167563477), SIMD3(0.0117218943, -0.0082844420, 0.9883948585)])
    let output = (xyzToAP1 * adaptation * cameraToXYZ) * (1 / sourceWhite.y)
    let transposed = output.transpose
    func row(_ a: SIMD3<Double>) -> SIMD4<Float> { .init(Float(a.x), Float(a.y), Float(a.z), 0) }
    rows = (row(transposed.columns.0), row(transposed.columns.1), row(transposed.columns.2))
    // Bound an ill-conditioned metadata matrix before feeding it a whole sensor surface.
    guard [rows.0, rows.1, rows.2].allSatisfy({ a in (0..<3).allSatisfy { abs(a[$0]) <= 1024 } }) else {
      throw Failure.invalidCalibration
    }
  }

  func apply(_ camera: SIMD3<Float>) -> SIMD3<Float> {
    let p = SIMD4(camera, 0)
    return .init(simd_dot(rows.0, p), simd_dot(rows.1, p), simd_dot(rows.2, p))
  }
}
