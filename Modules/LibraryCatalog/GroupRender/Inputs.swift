import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RenderIssue: LocalizedError {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}

struct Frame: Decodable {
  let path, fileID, assetID, captureID, contentID, sha256: String
  let byteCount: Int64
  let exposureSeconds: Double?
  let workVersionID: String?
}

struct Recipe: Decodable {
  var stackMode, projection, crop, sourceRenderingPolicy: String?
  var referenceIndex, bands: Int?
  var motionThreshold, foregroundStartY: Double?
  var deghost: Bool?
}

struct Request: Decodable {
  let jobID, operation: String
  let recipe: Recipe
  let outputURL: URL
  let frames: [Frame]
}

struct Input {
  let frame: Frame
  let local: URL
  let iso, aperture, shutter, focal35: Double?
  let clock: Double?
  let camera, serial, lens: String?
  let orientation: UInt32
  let neutral: CGPoint
  let size: CGSize
}

typealias Facts = [String: Any]
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let pixels = CIContext(options: [
  .workingColorSpace: linear, .outputColorSpace: linear,
  .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
])

func digest(_ file: URL, copyTo target: URL? = nil) throws -> (String, Int64) {
  let reader = try FileHandle(forReadingFrom: file)
  defer { try? reader.close() }
  var writer: FileHandle?
  if let target {
    let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw RenderIssue("private source copy unavailable") }
    writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
  defer { try? writer?.close() }
  var hash = SHA256()
  var length: Int64 = 0
  while let block = try reader.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
    hash.update(data: block)
    length += Int64(block.count)
    if let writer { try writer.write(contentsOf: block) }
  }
  return (hash.finalize().map { String(format: "%02x", $0) }.joined(), length)
}

func rawClock(_ exif: NSDictionary) -> Double? {
  guard let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
  let format = DateFormatter()
  format.locale = Locale(identifier: "en_US_POSIX")
  // Camera-local differences only. Do not invent an absolute time for a photograph.
  format.timeZone = TimeZone(secondsFromGMT: 0)
  format.dateFormat = "yyyy:MM:dd HH:mm:ss"
  guard let date = format.date(from: value) else { return nil }
  let sub =
    (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
    .flatMap { Double("0." + $0.trimmingCharacters(in: .whitespaces)) } ?? 0
  return date.timeIntervalSince1970 + sub
}

func loadInputs(_ request: Request, _ dir: URL) throws -> [Input] {
  guard ["starTrail", "hdr", "panorama"].contains(request.operation),
    (2...1024).contains(request.frames.count),
    Set(request.frames.map(\.captureID)).count == request.frames.count,
    Set(request.frames.map(\.sha256)).count == request.frames.count
  else { throw RenderIssue("frozen inputs must contain distinct captures and content") }
  return try request.frames.enumerated().map { index, frame in
    try autoreleasepool {
      guard frame.path.hasPrefix("/"), frame.sha256.count == 64, frame.byteCount > 0 else {
        throw RenderIssue("invalid frozen frame at index \(index)")
      }
      let original = URL(fileURLWithPath: frame.path)
      let local = dir.appendingPathComponent("source-\(index)").appendingPathExtension(
        original.pathExtension)
      let (actual, size) = try digest(original, copyTo: local)
      guard actual == frame.sha256.lowercased(), size == frame.byteCount else {
        throw RenderIssue("source digest or length changed at frozen index \(index)")
      }
      guard let src = CGImageSourceCreateWithURL(local as CFURL, nil),
        let type = CGImageSourceGetType(src),
        UTType(type as String)?.conforms(to: .rawImage) == true,
        let prop = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?,
        let raw = CIRAWFilter(imageURL: local)
      else {
        throw RenderIssue("verified camera RAW required at frozen index \(index)")
      }
      let exif = prop[kCGImagePropertyExifDictionary] as? NSDictionary ?? [:]
      let tiff = prop[kCGImagePropertyTIFFDictionary] as? NSDictionary ?? [:]
      let shutter = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
      if let expected = frame.exposureSeconds, let actual = shutter,
        abs(expected - actual) > max(1e-7, actual * 0.025)
      {
        throw RenderIssue("frozen shutter disagrees with RAW EXIF at index \(index)")
      }
      return Input(
        frame: frame, local: local,
        iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue,
        aperture: (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
        shutter: shutter,
        focal35: (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue,
        clock: rawClock(exif), camera: tiff[kCGImagePropertyTIFFModel] as? String,
        serial: exif[kCGImagePropertyExifBodySerialNumber] as? String,
        lens: exif[kCGImagePropertyExifLensModel] as? String, orientation: raw.orientation.rawValue,
        neutral: raw.neutralChromaticity, size: raw.nativeSize)
    }
  }
}

func rawImage(_ input: Input, neutral: CGPoint, scale: Float = 1) throws -> CIImage {
  guard let raw = CIRAWFilter(imageURL: input.local) else {
    throw RenderIssue("RAW decode unavailable")
  }
  raw.scaleFactor = scale
  raw.isDraftModeEnabled = false
  raw.exposure = 0
  raw.baselineExposure = 0
  raw.shadowBias = 0
  raw.boostAmount = 0
  raw.boostShadowAmount = 0
  raw.isGamutMappingEnabled = false
  raw.neutralChromaticity = neutral
  if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
  if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
  if raw.isContrastSupported { raw.contrastAmount = 0 }
  if raw.isDetailSupported { raw.detailAmount = 0 }
  if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
  if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
  if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
  if #available(macOS 26, *), raw.isHighlightRecoverySupported {
    raw.isHighlightRecoveryEnabled = false
  }
  guard let image = raw.outputImage else { throw RenderIssue("RAW decoder returned no full image") }
  let rect = image.extent.integral
  return image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
}

final class FloatBuffer {
  let p: UnsafeMutablePointer<Float>, count: Int
  private let byteCount: Int
  init(_ n: Int, file: URL? = nil) throws {
    guard n > 0, n <= 1_200_000_000 else {
      throw RenderIssue("image working extent exceeds the renderer limit")
    }
    count = n
    byteCount = n * MemoryLayout<Float>.size
    var fd: Int32 = -1
    if let file {
      fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw RenderIssue("cannot create private pixel scratch") }
      guard ftruncate(fd, off_t(byteCount)) == 0 else {
        close(fd)
        throw RenderIssue("insufficient scratch storage")
      }
      // Only the current renderer owns this mapping. The OS reclaims it if the process is killed.
      unlink(file.path)
    }
    let addr = mmap(
      nil, byteCount, PROT_READ | PROT_WRITE, fd < 0 ? MAP_PRIVATE | MAP_ANON : MAP_SHARED, fd, 0)
    if fd >= 0 { close(fd) }
    guard let addr, addr != MAP_FAILED else {
      throw RenderIssue("cannot allocate linear image scratch")
    }
    p = addr.assumingMemoryBound(to: Float.self)
  }
  deinit { munmap(p, byteCount) }
}

func renderInput(_ input: Input, neutral: CGPoint, scratch: URL? = nil) throws -> (
  FloatBuffer, Int, Int
) {
  try autoreleasepool {
    let image = try rawImage(input, neutral: neutral)
    let bounds = image.extent.integral
    let w = Int(bounds.width)
    let h = Int(bounds.height)
    guard w > 0, h > 0, w * h <= 200_000_000 else {
      throw RenderIssue("unsupported RAW dimensions")
    }
    let result = try FloatBuffer(w * h * 4, file: scratch)
    // CIRenderDestination's bitmap has top row first; the decoder applies EXIF orientation once.
    pixels.render(
      image, toBitmap: result.p, rowBytes: w * 16, bounds: bounds, format: .RGBAf,
      colorSpace: linear)
    return (result, w, h)
  }
}

struct Proxy {
  let data: [UInt8]
  let w, h: Int
}
func makeProxy(_ input: Input, neutral: CGPoint) throws -> Proxy {
  try autoreleasepool {
    let scale = Float(min(1, 1100 / max(input.size.width, input.size.height)))
    let im = try rawImage(input, neutral: neutral, scale: scale)
    let b = im.extent.integral
    let w = Int(b.width)
    let h = Int(b.height)
    guard w > 0, h > 0, w * h <= 5_000_000 else {
      throw RenderIssue("invalid registration proxy dimensions")
    }
    let f = try FloatBuffer(w * h * 4)
    pixels.render(
      im, toBitmap: f.p, rowBytes: w * 16, bounds: b, format: .RGBAf, colorSpace: linear)
    var gray = [UInt8](repeating: 0, count: w * h)
    gr_luma8(f.p, &gray, Int32(w * h))
    return Proxy(data: gray, w: w, h: h)
  }
}

func matches(_ a: Proxy, _ b: Proxy, focal: Double) throws -> (GRMatch, Int32) {
  guard a.w == b.w, a.h == b.h else {
    throw RenderIssue("inconsistent registration proxy dimensions")
  }
  var m = GRMatch()
  let status = gr_register(a.data, b.data, Int32(a.w), Int32(a.h), focal, &m)
  return (m, status)
}

func commonInputs(_ xs: [Input]) throws {
  guard let ref = xs.first, ref.camera != nil else {
    throw RenderIssue("camera identity is unavailable")
  }
  for x in xs
  where x.camera != ref.camera || x.serial != ref.serial || x.lens != ref.lens || x.size != ref.size
    || x.orientation != ref.orientation
  {
    throw RenderIssue("camera, lens, RAW dimensions or orientation differs among frozen inputs")
  }
}
