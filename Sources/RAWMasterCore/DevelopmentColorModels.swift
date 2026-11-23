import Foundation

// Strict object-key checks are shared by versioned recipe decoders, never by unrelated catalogue types.
struct RecipeCodingKey: CodingKey {
  let stringValue: String; var intValue: Int? { nil }
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}
enum RecipeCoding {
  static func requireKeys(_ decoder: Decoder, _ keys: [String]) throws {
    let object = try decoder.container(keyedBy: RecipeCodingKey.self)
    guard Set(object.allKeys.map(\.stringValue)) == Set(keys) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown or missing development recipe fields"))
    }
  }
}

public struct DevelopmentTones: Codable, Equatable, Sendable {
  public var contrast: Double
  public var highlights: Double
  public var shadows: Double
  public var whites: Double
  public var blacks: Double
  public var vibrance: Double
  public var saturation: Double
  public init(contrast: Double = 0, highlights: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0, vibrance: Double = 0, saturation: Double = 0) {
    self.contrast = contrast
    self.highlights = highlights
    self.shadows = shadows
    self.whites = whites
    self.blacks = blacks
    self.vibrance = vibrance
    self.saturation = saturation
  }
  public var isNeutral: Bool { contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0 && vibrance == 0 && saturation == 0 }
  public func validate() throws { try valuesInRange([contrast, highlights, shadows, whites, blacks, vibrance, saturation], -100...100) }
  private enum CodingKeys: String, CodingKey { case contrast, highlights, shadows, whites, blacks, vibrance, saturation }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    contrast = try container.decode(Double.self, forKey: .contrast)
    highlights = try container.decode(Double.self, forKey: .highlights)
    shadows = try container.decode(Double.self, forKey: .shadows)
    whites = try container.decode(Double.self, forKey: .whites)
    blacks = try container.decode(Double.self, forKey: .blacks)
    vibrance = try container.decode(Double.self, forKey: .vibrance)
    saturation = try container.decode(Double.self, forKey: .saturation)
    try validate()
  }
}

public struct DevelopmentCurves: Codable, Equatable, Sendable {
  public var rgb: DevelopmentCurve
  public var red: DevelopmentCurve
  public var green: DevelopmentCurve
  public var blue: DevelopmentCurve
  public init(rgb: DevelopmentCurve = .init(), red: DevelopmentCurve = .init(), green: DevelopmentCurve = .init(), blue: DevelopmentCurve = .init()) {
    self.rgb = rgb
    self.red = red
    self.green = green
    self.blue = blue
  }
  public var isNeutral: Bool { rgb.isNeutral && red.isNeutral && green.isNeutral && blue.isNeutral }
  public func validate() throws { try rgb.validate(); try red.validate(); try green.validate(); try blue.validate() }
  private enum CodingKeys: String, CodingKey { case rgb, red, green, blue }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["rgb", "red", "green", "blue"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rgb = try container.decode(DevelopmentCurve.self, forKey: .rgb)
    red = try container.decode(DevelopmentCurve.self, forKey: .red)
    green = try container.decode(DevelopmentCurve.self, forKey: .green)
    blue = try container.decode(DevelopmentCurve.self, forKey: .blue)
    try validate()
  }
}

public struct DevelopmentGradingWheel: Codable, Equatable, Sendable {
  public var hueDegrees: Double
  public var saturation: Double
  public var luminance: Double
  public init(hueDegrees: Double = 0, saturation: Double = 0, luminance: Double = 0) {
    self.hueDegrees = hueDegrees
    self.saturation = saturation
    self.luminance = luminance
  }
  public var isNeutral: Bool { saturation == 0 && luminance == 0 }
  public func validate() throws { guard hueDegrees.isFinite, (0..<360).contains(hueDegrees) else { throw EditingError.invalidRecipe }; try valuesInRange([saturation], 0...100); try valuesInRange([luminance], -100...100) }
  private enum CodingKeys: String, CodingKey { case hueDegrees, saturation, luminance }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["hueDegrees", "saturation", "luminance"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hueDegrees = try container.decode(Double.self, forKey: .hueDegrees)
    saturation = try container.decode(Double.self, forKey: .saturation)
    luminance = try container.decode(Double.self, forKey: .luminance)
    try validate()
  }
}

public struct DevelopmentColorGrading: Codable, Equatable, Sendable {
  public var shadows: DevelopmentGradingWheel
  public var midtones: DevelopmentGradingWheel
  public var highlights: DevelopmentGradingWheel
  public var global: DevelopmentGradingWheel
  public var blending: Double
  public var balance: Double
  /// Missing in existing recipes; a stored false bypasses the wheels without losing their values.
  public var enabled: Bool?
  public var isEnabled: Bool { enabled != false }
  public init(shadows: DevelopmentGradingWheel = .init(), midtones: DevelopmentGradingWheel = .init(), highlights: DevelopmentGradingWheel = .init(), global: DevelopmentGradingWheel = .init(), blending: Double = 50, balance: Double = 0, enabled: Bool? = nil) {
    self.shadows = shadows
    self.midtones = midtones
    self.highlights = highlights
    self.global = global
    self.blending = blending
    self.balance = balance
    self.enabled = enabled
  }
  public var isNeutral: Bool { !isEnabled || (shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral) }
  public func validate() throws { try shadows.validate(); try midtones.validate(); try highlights.validate(); try global.validate(); try valuesInRange([blending], 0...100); try valuesInRange([balance], -100...100) }
  private enum CodingKeys: String, CodingKey { case shadows, midtones, highlights, global, blending, balance, enabled }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try RecipeCoding.requireKeys(decoder, ["shadows", "midtones", "highlights", "global", "blending", "balance"]
      + (container.contains(.enabled) ? ["enabled"] : []))
    enabled = container.contains(.enabled) ? try container.decode(Bool.self, forKey: .enabled) : nil
    shadows = try container.decode(DevelopmentGradingWheel.self, forKey: .shadows)
    midtones = try container.decode(DevelopmentGradingWheel.self, forKey: .midtones)
    highlights = try container.decode(DevelopmentGradingWheel.self, forKey: .highlights)
    global = try container.decode(DevelopmentGradingWheel.self, forKey: .global)
    blending = try container.decode(Double.self, forKey: .blending)
    balance = try container.decode(Double.self, forKey: .balance)
    try validate()
  }
}

public struct DevelopmentColorAdjustments: Codable, Equatable, Sendable {
  public var tones: DevelopmentTones
  public var curves: DevelopmentCurves
  public var grading: DevelopmentColorGrading
  public init(tones: DevelopmentTones = .init(), curves: DevelopmentCurves = .init(), grading: DevelopmentColorGrading = .init()) {
    self.tones = tones
    self.curves = curves
    self.grading = grading
  }
  public var isNeutral: Bool { tones.isNeutral && curves.isNeutral && grading.isNeutral }
  public func validate() throws { try tones.validate(); try curves.validate(); try grading.validate() }
  private enum CodingKeys: String, CodingKey { case tones, curves, grading }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["tones", "curves", "grading"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tones = try container.decode(DevelopmentTones.self, forKey: .tones)
    curves = try container.decode(DevelopmentCurves.self, forKey: .curves)
    grading = try container.decode(DevelopmentColorGrading.self, forKey: .grading)
    try validate()
  }
}

private func valuesInRange(_ values: [Double], _ range: ClosedRange<Double>) throws {
  guard values.allSatisfy({ $0.isFinite && range.contains($0) }) else { throw EditingError.invalidRecipe }
}
public struct DevelopmentCurvePoint: Codable, Equatable, Sendable {
  public var x: Double, y: Double
  public init(x: Double, y: Double) { self.x = x; self.y = y }
  private enum CodingKeys: String, CodingKey { case x, y }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["x", "y"])
    let object = try decoder.container(keyedBy: CodingKeys.self)
    x = try object.decode(Double.self, forKey: .x); y = try object.decode(Double.self, forKey: .y)
    try valuesInRange([x,y], 0...1)
  }
}
public struct DevelopmentCurveSegment: Equatable, Sendable {
  public let lowerX: Double, upperX: Double, a: Double, b: Double, c: Double, d: Double
}
public struct DevelopmentCurve: Codable, Equatable, Sendable {
  public var points: [DevelopmentCurvePoint]
  public init(points: [DevelopmentCurvePoint] = [.init(x: 0,y: 0), .init(x: 1,y: 1)]) { self.points = points }
  public var isNeutral: Bool { points.allSatisfy { $0.x == $0.y } }
  public func validate() throws {
    guard (2...16).contains(points.count), points.first?.x == 0, points.last?.x == 1 else { throw EditingError.invalidRecipe }
    for (index, point) in points.enumerated() {
      try valuesInRange([point.x,point.y], 0...1)
      if index > 0, point.x < points[index-1].x + 1e-4 { throw EditingError.invalidRecipe }
    }
  }
  private enum CodingKeys: String, CodingKey { case points }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["points"])
    let object = try decoder.container(keyedBy: CodingKeys.self)
    var array = try object.nestedUnkeyedContainer(forKey: .points)
    guard let count = array.count, (2...16).contains(count) else { throw EditingError.invalidRecipe }
    points = []; points.reserveCapacity(count)
    while !array.isAtEnd { points.append(try array.decode(DevelopmentCurvePoint.self)) }
    try validate()
  }
  public func segments() throws -> [DevelopmentCurveSegment] {
    try validate()
    let n = points.count
    let h = (0..<n-1).map { points[$0+1].x - points[$0].x }
    let delta = (0..<n-1).map { (points[$0+1].y - points[$0].y) / h[$0] }
    var slopes = [Double](repeating: 0, count: n)
    if n == 2 { slopes = [delta[0], delta[0]] }
    else {
      for i in 1..<n-1 where delta[i-1] * delta[i] > 0 {
        let w1 = 2*h[i] + h[i-1], w2 = h[i] + 2*h[i-1]
        slopes[i] = (w1+w2) / (w1/delta[i-1] + w2/delta[i])
      }
      func endpoint(_ a: Double, _ b: Double, _ da: Double, _ db: Double) -> Double {
        let provisional = ((2*a+b)*da-a*db)/(a+b)
        if provisional * da <= 0 { return 0 }
        if da * db < 0 && abs(provisional) > 3*abs(da) { return 3*da }
        return provisional
      }
      slopes[0] = endpoint(h[0],h[1],delta[0],delta[1])
      slopes[n-1] = endpoint(h[n-2],h[n-3],delta[n-2],delta[n-3])
    }
    return (0..<n-1).map { i in
      let y0 = points[i].y, y1 = points[i+1].y, m0 = slopes[i], m1 = slopes[i+1], dx = h[i]
      return .init(lowerX: points[i].x, upperX: points[i+1].x,
        a: 2*y0-2*y1+dx*(m0+m1), b: -3*y0+3*y1-dx*(2*m0+m1), c: dx*m0, d: y0)
    }
  }
  public func value(at x: Double) throws -> Double {
    try validate(); guard x.isFinite else { throw EditingError.invalidRecipe }
    if isNeutral { return x }
    if x < 0 { return x + points[0].y }
    if x > 1 { return x + points[points.count-1].y - 1 }
    let pieces = try segments(), piece = pieces.first { x <= $0.upperX } ?? pieces[pieces.count-1]
    let t = (x-piece.lowerX)/(piece.upperX-piece.lowerX)
    return ((piece.a*t+piece.b)*t+piece.c)*t+piece.d
  }
}
