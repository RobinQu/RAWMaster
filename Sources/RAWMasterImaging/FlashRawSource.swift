import CFlashRaw
import CoreImage
import Foundation
import Metal
import RAWMasterCore

enum FlashRawError: LocalizedError, Equatable {
  case unavailable(String)
  case decode(String)
  case invalidFrame(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason): return "FlashRaw 引擎不可用（" + reason + "）"
    case .decode(let reason): return "FlashRaw 解码失败（" + reason + "）"
    case .invalidFrame(let reason): return "FlashRaw 图像输出无效（" + reason + "）"
    }
  }
}

enum FlashRawBackend: Int32 {
  case automatic = 0
  case cpu = 1
  case simd = 2
  case gpu = 3
}

enum FlashRawOutput: Int32 {
  case rawU16 = 0
  case normalizedF32 = 2
  case linearRGBF16 = 7
  case rgba8 = 4
}

enum FlashRawDemosaic: Int32 {
  case bilinear = 0
  case half = 1
  case edgeAware = 2
  case ahd = 3
  case automatic = 4
  /// Measurement-only override. Production remains bilinear until quality/performance gates pass.
  static var measurementOverride: Self {
    switch ProcessInfo.processInfo.environment["RAWMASTER_FLASHRAW_DEMOSAIC"] {
    case "ahd":.ahd; case "edge-aware":.edgeAware; case "half":.half; case "automatic":.automatic; default:.bilinear
    }
  }
}

struct FlashRawFrameInfo {
  let width: Int
  let height: Int
  let channels: Int
  let orientation: Int
  let originX: Int
  let originY: Int
  let sampleType: Int
  let outputFormat: Int
  let source: Int
  let incomplete: Bool

  init(_ value: rm_flashraw_frame_info) {
    width = Int(value.width); height = Int(value.height); channels = Int(value.channels)
    orientation = Int(value.orientation); originX = Int(value.origin_x); originY = Int(value.origin_y)
    sampleType = Int(value.sample_type); outputFormat = Int(value.output_format)
    source = Int(value.source); incomplete = value.incomplete != 0
  }
}

final class FlashRawFrame {
  let info: FlashRawFrameInfo
  private let handle: OpaquePointer
  private let source: FlashRawSource

  init(_ handle: OpaquePointer, source: FlashRawSource) {
    self.handle = handle
    self.source = source
    info = FlashRawFrameInfo(rm_flashraw_frame_get_info(handle))
  }

  func data() throws -> Data {
    var count = 0
    guard let pointer = rm_flashraw_frame_data(handle, &count), count > 0 else {
      throw FlashRawError.invalidFrame("empty pixel buffer")
    }
    // The Data shares the C buffer and retains its frame until every Core Image alias is gone.
    return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: count,
      deallocator: .custom { [self] _, _ in _ = self })
  }

  func sceneBayerMetadata() throws -> rm_flashraw_scene_bayer {
    var metadata = rm_flashraw_scene_bayer()
    guard rm_flashraw_frame_scene_bayer(handle, &metadata) != 0 else {
      throw FlashRawError.invalidFrame("scene intake requires an unbalanced Bayer mosaic with single database calibration")
    }
    return metadata
  }

  var statistics: FlashRawDecodeStatistics? {
    var stats = rm_flashraw_decode_statistics()
    guard rm_flashraw_frame_statistics(handle, &stats) != 0 else { return nil }
    // Stable flashraw_stage indices in the vendored C ABI. The native clocks may overlap.
    let names = ["containerParse","metadata","entropyDecode","unpack","predictor","calibration",
                 "postprocess","gpuUpload","gpuCompute","gpuDownload","preview"]
    let stages = withUnsafeBytes(of: &stats.stage_ms) { raw in
      zip(names, raw.bindMemory(to: Double.self)).map { FlashRawDecodeStatistics.Stage(name:$0, milliseconds:$1) }
    }
    return .init(decoderBackend: stats.backend.map { String(cString:$0) } ?? "unknown",
      postprocessBackend: stats.postprocess_backend.map { String(cString:$0) }, availableThreads:Int(stats.threads),
      inputBytes:stats.input_bytes,outputBytes:stats.output_bytes,nativeWallMilliseconds:stats.total_ms,stages:stages)
  }

  deinit { rm_flashraw_frame_free(handle) }
}

final class FlashRawSource {
  private let handle: OpaquePointer
  let decoderVersion: String

  static var bundledLibraryPath: String? {
    let environment = ProcessInfo.processInfo.environment
    if let explicit = environment["RAWMASTER_FLASHRAW_LIBRARY"], !explicit.isEmpty { return explicit }
    return Bundle.main.resourceURL?
      .appendingPathComponent("FlashRaw/libflashraw_capi.dylib").path
  }

  static var isAvailable: Bool {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FLASHRAW_DISABLE"] != "1",
          let path = bundledLibraryPath else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  static func open(_ url: URL) throws -> FlashRawSource {
    guard isAvailable, let library = bundledLibraryPath else {
      throw FlashRawError.unavailable("FlashRaw library is not installed")
    }
    return try FlashRawSource(url: url, libraryPath: library)
  }

  private init(url: URL, libraryPath: String) throws {
    var error = [CChar](repeating: 0, count: 2048)
    guard let handle = rm_flashraw_open(url.path, libraryPath, &error, error.count) else {
      throw FlashRawError.unavailable(String(cString: error))
    }
    self.handle = handle
    decoderVersion = rm_flashraw_version(handle).map { String(cString: $0) } ?? "unknown"
  }

  var rawDetails: DevelopmentRawDetails? {
    switch rm_flashraw_sensor_layout(handle) {
    case 0: .bayerAHD
    case 1: .xTransEdgeAware
    default: nil
    }
  }
  func demosaic(for details: DevelopmentRawDetails?, fallback: FlashRawDemosaic = .bilinear) throws -> FlashRawDemosaic {
    guard let details else { return fallback }
    guard decoderVersion == "0.3.1", details == rawDetails else {
      throw FlashRawError.invalidFrame("RAW 细节算法与此文件的传感器布局不匹配")
    }
    return details == .bayerAHD ? .ahd : .edgeAware
  }
  func decode(output: FlashRawOutput, backend: FlashRawBackend = .gpu,
              demosaic: FlashRawDemosaic = .bilinear, region: CGRect? = nil) throws -> FlashRawFrame {
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: "FlashRaw.decode",
      stage: "output \(output.rawValue) · backend \(backend.rawValue) · \(demosaic) · \(region == nil ? "全图" : "区域")",
      queue: "FlashRaw 解码", boundary: .decode)
    var outcome = ImagePerformanceOutcome.failed
    var pixelCount = 0, byteCount = 0
    var statistics: FlashRawDecodeStatistics?
    defer {
      ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome, pixelCount: pixelCount, byteCount: byteCount, flashRaw: statistics)
    }
    var error = [CChar](repeating: 0, count: 2048)
    var frame: OpaquePointer?
    let rect = try Self.checkedDecodeRegion(region)
    let status = rm_flashraw_decode(handle, backend.rawValue, output.rawValue, demosaic.rawValue,
      region == nil ? 0 : 1, rect.x, rect.y, rect.z, rect.w, &frame, &error, error.count)
    guard status == 0, let frame else { throw FlashRawError.decode(String(cString: error)) }
    let result = FlashRawFrame(frame, source: self)
    let bytesPerSample = switch result.info.sampleType {
    case 1: 1
    case 2, 4: 2
    case 3: 4
    default: 0
    }
    let (area, areaOverflow) = result.info.width.multipliedReportingOverflow(by: result.info.height)
    let (samples, sampleOverflow) = area.multipliedReportingOverflow(by: result.info.channels)
    let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: bytesPerSample)
    guard !areaOverflow, !sampleOverflow, !byteOverflow, bytes > 0 else { throw FlashRawError.invalidFrame("invalid pixel dimensions or sample type") }
    pixelCount = area
    byteCount = bytes
    statistics = result.statistics
    outcome = .succeeded
    return result
  }

  static func checkedDecodeRegion(_ region: CGRect?) throws -> SIMD4<UInt32> {
    guard let region else { return .zero }
    guard let x = UInt32(exactly: region.origin.x), let y = UInt32(exactly: region.origin.y),
          let width = UInt32(exactly: region.size.width), width > 0,
          let height = UInt32(exactly: region.size.height), height > 0,
          !x.addingReportingOverflow(width).overflow, !y.addingReportingOverflow(height).overflow else {
      throw FlashRawError.invalidFrame("ROI must lie on the unsigned integer pixel grid")
    }
    return .init(x,y,width,height)
  }

  func sceneSensorSize() throws -> (width: Int, height: Int) {
    var width: UInt32 = 0, height: UInt32 = 0
    guard rm_flashraw_scene_dimensions(handle, &width, &height) != 0 else {
      throw FlashRawError.invalidFrame("scene intake requires a supported ARW sensor buffer")
    }
    return (Int(width), Int(height))
  }

  var geometry: (width: Int, height: Int, orientation: Int) {
    var width: UInt32 = 0, height: UInt32 = 0, orientation: UInt32 = 0
    rm_flashraw_geometry(handle, &width, &height, &orientation)
    return (Int(width), Int(height), Int(orientation))
  }

  deinit { rm_flashraw_close(handle) }
}

extension FlashRawFrame {
  func linearRGBF16Data() throws -> Data {
    guard info.outputFormat == FlashRawOutput.linearRGBF16.rawValue,
          info.channels == 3, info.sampleType == 4, info.source == 0, !info.incomplete,
          info.width > 0, info.height > 0 else {
      throw FlashRawError.invalidFrame("expected complete linear RGB F16 sensor frame")
    }
    let bytes = try data()
    let (pixels, areaOverflow) = info.width.multipliedReportingOverflow(by: info.height)
    let (length, byteOverflow) = pixels.multipliedReportingOverflow(by: 6)
    guard !areaOverflow, !byteOverflow, length == bytes.count else {
      throw FlashRawError.invalidFrame("linear F16 buffer length disagrees with its dimensions")
    }
    return bytes
  }

  func linearMetalBuffer(device: MTLDevice) throws -> MTLBuffer {
    let bytes = try linearRGBF16Data()
    return try bytes.withUnsafeBytes { raw in
      guard let address = raw.baseAddress else { throw FlashRawError.invalidFrame("missing linear pixels") }
      guard let buffer = device.makeBuffer(bytes: address, length: raw.count, options: .storageModeShared) else {
        throw FlashRawError.invalidFrame("cannot create the Metal source buffer")
      }
      return buffer
    }
  }

  func displayImage() throws -> CIImage {
    guard info.outputFormat == FlashRawOutput.rgba8.rawValue,
          info.channels == 4, info.sampleType == 1, info.source == 0, !info.incomplete,
          info.width > 0, info.height > 0 else {
      throw FlashRawError.invalidFrame("expected complete RGBA8 display frame")
    }
    return CIImage(bitmapData: try data(), bytesPerRow: info.width * 4,
      size: CGSize(width: info.width, height: info.height), format: .RGBA8,
      colorSpace: PhotoRenderer.sRGB)
  }
}
