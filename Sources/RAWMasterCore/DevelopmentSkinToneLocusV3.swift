import Foundation

public struct DevelopmentChromaticityV3: Equatable, Sendable {
  public let x, y: Double
  public init(x: Double, y: Double) { self.x = x; self.y = y }
}
/// Own version1 skin-locus estimator, shared by manual and automatic source sampling. Its
/// temporary xy is not persisted: only the native TT readback is the resolved replay authority.
public enum DevelopmentSkinToneLocusV3 {
  public static let version = "rawmaster-skin-locus-v1/linearRGB-.45-.28-.20/D65-Bradford"
  public static let targetLinearRGB = DevelopmentSampledColorV3(red:0.45,green:0.28,blue:0.20)
  public static func validateSample(_ c: DevelopmentSampledColorV3, alpha: Double) throws {
    try c.validate()
    guard alpha.isFinite, alpha > 0, alpha <= 1 else { throw EditingError.invalidRecipe }
    let rgb = [c.red,c.green,c.blue]
    let y = DevelopmentImageWhiteBalancePickV3.rgbToXYZ[3]*c.red+DevelopmentImageWhiteBalancePickV3.rgbToXYZ[4]*c.green+DevelopmentImageWhiteBalancePickV3.rgbToXYZ[5]*c.blue
    func encode(_ x: Double) -> Double { x <= 0.0031308 ? 12.92*x:1.055*pow(x,1/2.4)-0.055 }
    guard rgb.allSatisfy({ $0 > 0.002 }), y >= 0.02, y <= 0.85 else { throw EditingError.invalidRecipe }
    let e = rgb.map(encode), high = e.max()!, low = e.min()!, chroma = high-low
    guard high < 0.98, chroma >= 0.04, e[0] > e[1], e[1] > e[2] else { throw EditingError.invalidRecipe }
    let saturation = chroma/high, hue = (e[1]-e[2])/chroma/6
    guard (0.1...0.8).contains(saturation), (0.02...0.15).contains(hue) else { throw EditingError.invalidRecipe }
  }
  public static func illuminant(assumingGray xy: DevelopmentChromaticityV3, sample: DevelopmentSampledColorV3, alpha: Double) throws -> DevelopmentChromaticityV3 {
    try validateSample(sample,alpha:alpha)
    guard xy.x.isFinite, xy.y.isFinite, xy.x > 0, xy.y > 0, xy.x+xy.y < 1 else { throw EditingError.invalidRecipe }
    let b = DevelopmentImageWhiteBalancePickV3.bradford, c = DevelopmentImageWhiteBalancePickV3.rgbToXYZ
    let grayXYZ = [xy.x/xy.y,1,(1-xy.x-xy.y)/xy.y]
    let skinXYZ = DevelopmentRGBMatrixV3.apply(c,[targetLinearRGB.red,targetLinearRGB.green,targetLinearRGB.blue])
    let grayLMS = DevelopmentRGBMatrixV3.apply(b,grayXYZ)
    let d65LMS = DevelopmentRGBMatrixV3.apply(b,[0.95047,1,1.08883])
    let skinLMS = DevelopmentRGBMatrixV3.apply(b,skinXYZ)
    guard (grayLMS+d65LMS+skinLMS).allSatisfy({ $0.isFinite && $0 > 1e-8 }) else { throw EditingError.invalidRecipe }
    // Remove the target skin reflectance from the same actual pixel's gray-as-neutral estimate.
    let lms = (0..<3).map { grayLMS[$0]*d65LMS[$0]/skinLMS[$0] }
    let xyz = DevelopmentRGBMatrixV3.apply(try DevelopmentRGBMatrixV3.inverse(b),lms)
    guard xyz.allSatisfy({ $0.isFinite && $0 > 1e-8 }) else { throw EditingError.invalidRecipe }
    let sum = xyz.reduce(0,+), result = DevelopmentChromaticityV3(x:xyz[0]/sum,y:xyz[1]/sum)
    guard sum.isFinite, sum > 0, result.x.isFinite, result.y.isFinite, result.x > 0, result.y > 0, result.x+result.y < 1 else { throw EditingError.invalidRecipe }
    return result
  }
  /// Validation precedes BOTH callbacks, so invalid manual/proxy samples cannot touch native WB.
  public static func resolvingNativeTarget(sample: DevelopmentSampledColorV3, alpha: Double,
    estimateGray: () throws -> DevelopmentChromaticityV3,
    assignSkin: (DevelopmentChromaticityV3) throws -> DevelopmentNativeWhiteBalanceV3) throws -> DevelopmentNativeWhiteBalanceV3 {
    try validateSample(sample,alpha:alpha)
    let xy = try illuminant(assumingGray:estimateGray(),sample:sample,alpha:alpha)
    let target = try assignSkin(xy); try target.validate(); return target
  }
}
