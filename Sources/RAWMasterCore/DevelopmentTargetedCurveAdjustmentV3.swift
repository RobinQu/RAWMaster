import Foundation

public enum DevelopmentCurveChannelV3ID: String, Sendable { case rgb, red, green, blue }

/// Point-curve targeted drag starts from the recipe produced by the source sampling transaction.
/// Every update uses that same point and baseline; horizontal motion changes input, vertical changes output.
public enum DevelopmentTargetedCurveAdjustmentV3 {
  public enum Region: Equatable, Sendable {
    case shadows, darks, lights, highlights
    fileprivate var amount: WritableKeyPath<DevelopmentParametricCurveV3, Double> {
      switch self {
      case .shadows: return \.shadows
      case .darks: return \.darks
      case .lights: return \.lights
      case .highlights: return \.highlights
      }
    }
  }

  public static func region(tone: Double, curve: DevelopmentParametricCurveV3) throws -> Region {
    try curve.validate()
    guard tone.isFinite, (0...1).contains(tone) else { throw EditingError.invalidRecipe }
    if tone < curve.split1 { return .shadows }
    if tone < curve.split2 { return .darks }
    if tone < curve.split3 { return .lights }
    return .highlights
  }

  public static func applyParametric(initial: DevelopmentCurvesV3, region: Region,
                                     translation: SIMD2<Double>) throws -> DevelopmentCurvesV3 {
    try initial.validate()
    guard [translation.x, translation.y].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
      throw EditingError.invalidRecipe
    }
    // Horizontal or vertical drags each cover the slider's range. A diagonal uses its dominant axis.
    let delta = abs(translation.x) > abs(translation.y) ? translation.x : translation.y
    guard delta != 0 else { return initial }
    var curve = initial.parametric ?? .init()
    curve[keyPath: region.amount] = min(100, max(-100, curve[keyPath: region.amount] + 200 * delta))
    var next = initial
    next.parametric = curve
    next.enabled = true
    return next
  }

  public static func applyPoint(initial:DevelopmentCurvesV3,channel:DevelopmentCurveChannelV3ID,
                                pointIndex:Int,translation:SIMD2<Double>)throws->DevelopmentCurvesV3 {
    guard translation.x.isFinite,translation.y.isFinite,(-1...1).contains(translation.x),(-1...1).contains(translation.y) else{throw EditingError.invalidRecipe}
    var target=read(initial,channel:channel)
    guard target.curve.points.indices.contains(pointIndex) else{throw EditingError.invalidRecipe}
    let point=target.curve.points[pointIndex]
    let lower:Double,upper:Double
    if pointIndex==0{lower=0;upper=0}
    else if pointIndex==target.curve.points.count-1{lower=1;upper=1}
    else{
      lower=target.curve.points[pointIndex-1].x+0.0001000001
      upper=target.curve.points[pointIndex+1].x-0.0001000001
    }
    guard lower<=upper else{throw EditingError.invalidRecipe}
    let x=min(upper,max(lower,point.x+translation.x)),y=min(1,max(0,point.y+translation.y))
    target.curve.points[pointIndex] = .init(x:x,y:y);try target.validate()
    var next=initial;write(&next,target,channel:channel);next.enabled=true;try next.validate();return next
  }
  private static func read(_ value:DevelopmentCurvesV3,channel:DevelopmentCurveChannelV3ID)->DevelopmentCurveChannelV3 {
    switch channel {case .rgb:value.rgb;case .red:value.red;case .green:value.green;case .blue:value.blue}
  }
  private static func write(_ value:inout DevelopmentCurvesV3,_ target:DevelopmentCurveChannelV3,channel:DevelopmentCurveChannelV3ID) {
    switch channel {case .rgb:value.rgb=target;case .red:value.red=target;case .green:value.green=target;case .blue:value.blue=target}
  }
}
