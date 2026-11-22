import Foundation

/// Deterministic HSL targeted drag. The sampling transaction and the drag share one editing gesture;
/// every update starts from the same pre-drag parameter snapshot rather than accumulating deltas.
public enum DevelopmentTargetedColorAdjustmentV3 {
  public static func apply(initial: DevelopmentSelectiveColorV3, sample: DevelopmentSampledColorV3,
                           mode: DevelopmentTargetedColorAttributeV3, drag: Double) throws -> DevelopmentSelectiveColorV3 {
    guard drag.isFinite,(-1...1).contains(drag) else { throw EditingError.invalidRecipe }
    try sample.validate();try initial.validate()
    var next=initial
    for required in DevelopmentSelectiveColorSlotV3.allCases where !next.colors.contains(where:{$0.slot == required}) {
      next.colors.append(.init(slot:required))
    }
    let target=hue(sample)
    for index in next.colors.indices {
      let color=next.colors[index]
      let center=color.sampledColor.map(hue) ?? Double(DevelopmentSelectiveColorSlotV3.allCases.firstIndex(of:color.slot) ?? 0)/Double(DevelopmentSelectiveColorSlotV3.allCases.count)
      let distance=min(abs(center-target),1-abs(center-target))
      let weight=pow(max(0,1-distance/0.25),2)
      let delta=drag*weight
      switch mode {
      case .hue:colorSet(&next.colors[index],\.hue,clamp(color.hue+delta*60,-60,60))
      case .saturation:colorSet(&next.colors[index],\.saturation,clamp(color.saturation+delta*100,-100,100))
      case .luminance:colorSet(&next.colors[index],\.luminance,clamp(color.luminance+delta*70,-70,70))
      }
    }
    next.enabled=true;try next.validate();return next
  }
  private static func colorSet(_ color:inout DevelopmentSelectiveColorAdjustmentV3,
                               _ path:WritableKeyPath<DevelopmentSelectiveColorAdjustmentV3,Double>,_ value:Double) {
    color[keyPath:path]=value
  }
  private static func clamp(_ value:Double,_ lower:Double,_ upper:Double)->Double {min(upper,max(lower,value))}
  private static func encoded(_ value:Double)->Double {
    value<=0.0031308 ? 12.92*value:1.055*pow(value,1/2.4)-0.055
  }
  private static func hue(_ sample:DevelopmentSampledColorV3)->Double {
    let r=encoded(sample.red),g=encoded(sample.green),b=encoded(sample.blue)
    let high=max(r,max(g,b)),low=min(r,min(g,b)),delta=high-low
    guard delta>1e-12 else{return 0}
    let value:Double
    if high==r {value=(g-b)/delta}
    else if high==g {value=2+(b-r)/delta}
    else {value=4+(r-g)/delta}
    let turns=value/6;return turns<0 ? turns+1:turns
  }
}

/// Core-owned attribute domain avoids making the image model depend on a SwiftUI view enum.
public enum DevelopmentTargetedColorAttributeV3: String, Sendable { case hue, saturation, luminance }
