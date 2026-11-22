import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// Raw sensor coordinates and image rectangles use top-left origin; EXIF is applied exactly once.
public struct LibraryInspectionGeometry: Sendable {
  public let original: CGSize
  public let orientation: Int
  public let rotationDegrees: Double
  public let crop: CGRect
  public let viewport: CGSize
  public let zoom: Double
  public let pan: CGPoint

  public init(
    original: CGSize, orientation: Int, rotationDegrees: Double = 0,
    crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), viewport: CGSize,
    zoom: Double = 1, pan: CGPoint = .zero
  ) {
    self.original = original
    self.orientation = orientation
    self.rotationDegrees = rotationDegrees
    self.crop = crop
    self.viewport = viewport
    self.zoom = zoom
    self.pan = pan
  }

  public static func oriented(_ p: CGPoint, exif: Int) -> CGPoint? {
    switch exif {
    case 1: p
    case 2: CGPoint(x: 1 - p.x, y: p.y)
    case 3: CGPoint(x: 1 - p.x, y: 1 - p.y)
    case 4: CGPoint(x: p.x, y: 1 - p.y)
    case 5: CGPoint(x: p.y, y: p.x)
    case 6: CGPoint(x: 1 - p.y, y: p.x)
    case 7: CGPoint(x: 1 - p.y, y: 1 - p.x)
    case 8: CGPoint(x: p.y, y: 1 - p.x)
    default: nil
    }
  }
  private func projected(_ point: CGPoint, includeOutside: Bool) -> CGPoint? {
    guard let p = Self.oriented(point, exif: orientation), original.width > 0, original.height > 0,
      viewport.width > 0, viewport.height > 0, zoom.isFinite, zoom > 0,
      (-45...45).contains(rotationDegrees), crop.width > 0, crop.height > 0,
      crop.minX >= 0, crop.minY >= 0, crop.maxX <= 1, crop.maxY <= 1
    else { return nil }
    let w = orientation >= 5 ? original.height : original.width
    let h = orientation >= 5 ? original.width : original.height
    let angle = rotationDegrees * .pi / 180
    let s = sin(angle)
    let c = cos(angle)
    let a = abs(s)
    let trimmed: CGSize
    if a < 1e-12 {
      trimmed = .init(width: w, height: h)
    } else if min(w, h) <= 2 * a * c * max(w, h) || abs(c - a) < 1e-10 {
      let half = min(w, h) / 2
      trimmed =
        w >= h ? .init(width: half / a, height: half / c) : .init(width: half / c, height: half / a)
    } else {
      let d = c * c - a * a
      trimmed = .init(width: (w * c - h * a) / d, height: (h * c - w * a) / d)
    }
    // Core Image's positive angle is counterclockwise in bottom-left coordinates.
    let dx = (p.x - 0.5) * w
    let dy = (p.y - 0.5) * h
    let x = (c * dx + s * dy) / trimmed.width + 0.5
    let y = (-s * dx + c * dy) / trimmed.height + 0.5
    let nx = (x - crop.minX) / crop.width
    let ny = (y - crop.minY) / crop.height
    if !includeOutside && (!(0...1).contains(nx) || !(0...1).contains(ny)) { return nil }
    let cw = trimmed.width * crop.width
    let ch = trimmed.height * crop.height
    let scale = min(viewport.width / cw, viewport.height / ch) * zoom
    return .init(
      x: viewport.width / 2 + pan.x + (nx - 0.5) * cw * scale,
      y: viewport.height / 2 + pan.y + (ny - 0.5) * ch * scale)
  }
  public func displayPoint(forRaw point: CGPoint) -> CGPoint? {
    projected(point, includeOutside: false)
  }
  public func rawPoint(forDisplay p: CGPoint) -> CGPoint? {
    guard let o = projected(.zero, includeOutside: true),
      let a = projected(.init(x: 1, y: 0), includeOutside: true),
      let b = projected(.init(x: 0, y: 1), includeOutside: true)
    else { return nil }
    let ax = a.x - o.x
    let ay = a.y - o.y
    let bx = b.x - o.x
    let by = b.y - o.y
    let det = ax * by - ay * bx
    guard abs(det) > 1e-12 else { return nil }
    let x = p.x - o.x
    let y = p.y - o.y
    let raw = CGPoint(x: (x * by - y * bx) / det, y: (ax * y - ay * x) / det)
    guard (0...1).contains(raw.x), (0...1).contains(raw.y), displayPoint(forRaw: raw) != nil else {
      return nil
    }
    return raw
  }
}
