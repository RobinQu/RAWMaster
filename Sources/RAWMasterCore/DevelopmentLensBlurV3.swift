import Foundation

public enum DevelopmentLensBokehStyleV3:String,Codable,CaseIterable,Sendable {case circle,bubble,fiveBlade,ring,anamorphic}

/// Persisted optical controls and optional source-derived depth maps.
public struct DevelopmentLensBlurV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var amount: Double
  public var focusX, focusY: Double
  public var focusRange: Double
  /// Nil retains Circle and keeps pre-Bokeh recipe bytes unchanged.
  public var bokehStyle: DevelopmentLensBokehStyleV3?
  /// Optional owned edge-shape and defocused-highlight controls.
  public var catEyeAmount, bokehBoost: Double?
  /// Actual device depth/disparity supplied by ImageIO. Nil retains the procedural focus plane.
  public var deviceDepth: DevelopmentLensBlurDepthPayloadV1?
  public var sceneDepth: DevelopmentSceneDepthV1?
  public var renderDepth: DevelopmentLensBlurDepthPayloadV1? { deviceDepth ?? sceneDepth?.map }
  /// Ephemeral visualization intent used only by the temporary preview recipe.
  public var visualiseDepth: Bool?
  /// Nil keeps pre-refinement recipe bytes unchanged. Strokes store source-normalized coordinates.
  public var refinementBrush: DevelopmentLensBlurRefinementBrushV3?
  public var refinementStrokes: [DevelopmentLensBlurRefinementStrokeV3]?
  public init(enabled:Bool=false,amount:Double=0.5,focusX:Double=0.5,focusY:Double=0.5,focusRange:Double=0.2,
              bokehStyle:DevelopmentLensBokehStyleV3?=nil,catEyeAmount:Double?=nil,bokehBoost:Double?=nil,
              deviceDepth:DevelopmentLensBlurDepthPayloadV1?=nil,visualiseDepth:Bool?=nil,
              refinementBrush:DevelopmentLensBlurRefinementBrushV3?=nil,refinementStrokes:[DevelopmentLensBlurRefinementStrokeV3]?=nil) {
    self.enabled=enabled;self.amount=amount;self.focusX=focusX;self.focusY=focusY;self.focusRange=focusRange
    self.bokehStyle=bokehStyle;self.catEyeAmount=catEyeAmount;self.bokehBoost=bokehBoost;self.deviceDepth=deviceDepth;self.visualiseDepth=visualiseDepth
    self.refinementBrush=refinementBrush;self.refinementStrokes=refinementStrokes
  }
  public var isActive:Bool{enabled && amount>0}
  public mutating func focus(at point: DevelopmentSourcePoint) throws {
    try point.validate()
    var next = self
    next.enabled = true
    next.focusX = point.x
    next.focusY = point.y
    try next.validate()
    self = next
  }

  public mutating func focus(from start: DevelopmentSourcePoint, to end: DevelopmentSourcePoint,
                             sourceSize: DevelopmentPixelSize) throws {
    try start.validate(); try end.validate(); try sourceSize.validate()
    let width = Double(sourceSize.width), height = Double(sourceSize.height)
    var next = self
    next.focusRange = min(1, max(0.01, hypot((end.x-start.x)*width, (end.y-start.y)*height) / min(width,height)))
    try next.focus(at: .init(x:(start.x+end.x)/2, y:(start.y+end.y)/2))
    self = next
  }

  public func validate()throws{
    try DevelopmentV3Validation.range([amount,focusX,focusY,focusRange],0...1)
    if let catEyeAmount{try DevelopmentV3Validation.range([catEyeAmount],0...1)}
    if let bokehBoost{try DevelopmentV3Validation.range([bokehBoost],0...1)}
    try deviceDepth?.validate(); try sceneDepth?.validate(); try refinementBrush?.validate()
    if let refinementStrokes{try DevelopmentLensBlurRefinementStrokeV3.validateStrokes(refinementStrokes)}
  }
}
