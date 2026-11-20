import CFlashRaw
import CoreImage
import Foundation
import Metal

enum FlashRawError: Error, Equatable {
  case unavailable(String)
  case decode(String)
  case invalidFrame(String)
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
    guard let library = bundledLibraryPath else {
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

  func decode(output: FlashRawOutput, backend: FlashRawBackend = .gpu,
              demosaic: FlashRawDemosaic = .bilinear, region: CGRect? = nil) throws -> FlashRawFrame {
    var error = [CChar](repeating: 0, count: 2048)
    var frame: OpaquePointer?
    let status = rm_flashraw_decode(handle, backend.rawValue, output.rawValue, demosaic.rawValue,
      region == nil ? 0 : 1, UInt32(region?.minX ?? 0), UInt32(region?.minY ?? 0),
      UInt32(region?.width ?? 0), UInt32(region?.height ?? 0), &frame, &error, error.count)
    guard status == 0, let frame else { throw FlashRawError.decode(String(cString: error)) }
    return FlashRawFrame(frame, source: self)
  }

  deinit { rm_flashraw_close(handle) }
}

extension FlashRawFrame {
  func linearMetalBuffer(device: MTLDevice) throws -> MTLBuffer {
    guard info.outputFormat == FlashRawOutput.linearRGBF16.rawValue,
          info.channels == 3, info.sampleType == 4, info.source == 0, !info.incomplete,
          info.width > 0, info.height > 0 else {
      throw FlashRawError.invalidFrame("expected complete linear RGB F16 sensor frame")
    }
    let bytes = try data()
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
