import Foundation
import Metal
import RAWMasterCore

/// The display grid here is exactly the working grid, including its origin. The
/// transfer shares the canonical GPU formula. Coordinates are symmetric about
/// the canvas centre, so Metal's top-origin row has the same radial distance.
struct PreviewMetalPostCrop {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_PROXY_METAL_POST_CROP"] != "0"
  let amount, options: SIMD4<Float>

  init(_ value: DevelopmentPostCropVignetteV3) throws {
    try value.validate()
    let style: Float = switch value.style { case .highlightPriority:0; case .colorPriority:1; case .paintOverlay:2 }
    amount = .init(Float(value.amount/100),Float(value.midpoint/100),Float(value.roundness/100),0)
    options = .init(Float(value.feather/100),Float(value.highlights/100),style,0)
  }

  static let metal = #"""
float pcvY(float3 c) { return dot(c,float3(.2126,.7152,.0722)); }
float4 displayPostCrop(float4 p,float2 pixel,float2 size,float4 amount,float4 options) {
 if(!all(isfinite(p))||p.a<=0)return p;
 float2 centered=pixel-size*.5;
 float2 oval=centered/(size*.5);
 float2 circle=centered/(min(size.x,size.y)*.5);
\#(DevelopmentPostCropVignetteEngineV3.pixelTransferMetal)
}
"""#
}
