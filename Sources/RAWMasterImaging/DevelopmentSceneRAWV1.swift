import CoreImage
import Foundation
import Metal
import RAWMasterCore


final class DevelopmentSceneRAWV1 {
  enum Failure: Error, Equatable { case surfaceBudget }
  typealias Calibration = DevelopmentCameraCalibrationV1
  typealias Color = DevelopmentSceneColorV1

  struct Sensor {
    let width, height, orientation: Int
    let active, crop: SIMD4<UInt32>
    let colors: SIMD4<UInt32>
    let black, white: SIMD4<Float>
    let calibration: Calibration

    init(width: Int, height: Int, orientation: Int, active: SIMD4<UInt32>, crop: SIMD4<UInt32>,
         colors: SIMD4<UInt32>, black: SIMD4<Float>, white: SIMD4<Float>, calibration: Calibration) throws {
      guard (2...16_384).contains(width), (2...16_384).contains(height), width * height <= 65_000_000,
            (1...8).contains(orientation) else { throw Calibration.Failure.invalidGeometry }
      func enclosed(_ child: SIMD4<UInt32>, by parent: SIMD4<UInt32>) -> Bool {
        child.x >= parent.x && child.y >= parent.y && child.z >= 2 && child.w >= 2 &&
          UInt64(child.x) + UInt64(child.z) <= UInt64(parent.x) + UInt64(parent.z) &&
          UInt64(child.y) + UInt64(child.w) <= UInt64(parent.y) + UInt64(parent.w)
      }
      guard enclosed(active, by: .init(0, 0, UInt32(width), UInt32(height))), enclosed(crop, by: active) else {
        throw Calibration.Failure.invalidGeometry
      }
      guard (colors[0] == 1 && colors[3] == 1 && Set([colors[1], colors[2]]) == [0, 2]) ||
            (colors[1] == 1 && colors[2] == 1 && Set([colors[0], colors[3]]) == [0, 2]),
            (0..<4).allSatisfy({ black[$0].isFinite && white[$0].isFinite && black[$0] >= 0 &&
              white[$0] <= Float(UInt16.max) && white[$0] - black[$0] >= 1 }) else {
        throw Calibration.Failure.invalidMosaic
      }
      self.width=width; self.height=height; self.orientation=orientation; self.active=active; self.crop=crop
      self.colors=colors; self.black=black; self.white=white; self.calibration=calibration
    }

    var size: SIMD2<UInt32> { orientation < 5 ? .init(crop.z, crop.w) : .init(crop.w, crop.z) }
  }

  struct Result {
    let image: DevelopmentSceneMetalV1.Image
    // Bits 0, 1 and 2 are measured saturation of contributing R, G and B sensels.
    let sensorSaturation: MTLTexture
  }

  private struct Parameters {
    let active, crop, colors, output: SIMD4<UInt32>
    let black, white, red, green, blue: SIMD4<Float>
  }
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice) throws {
    guard let queue = device.makeCommandQueue() else { throw Color.Failure.metalUnavailable }
    let options = MTLCompileOptions()
    options.mathMode = .safe
    let library = try device.makeLibrary(source: Self.kernel, options: options)
    guard let function = library.makeFunction(name: "rmSceneBayerV1") else { throw Color.Failure.metalUnavailable }
    self.pipeline = try device.makeComputePipelineState(function: function)
    self.device=device; self.queue=queue
  }

  func decode(_ url: URL, region: MTLRegion? = nil, maximumOutputBytes: Int? = nil) throws -> Result {
    let (frame, sensor) = try Self.sensorFrame(url)
    if let maximumOutputBytes, region == nil, Int(sensor.size.x) * Int(sensor.size.y) > maximumOutputBytes / 17 {
      throw Failure.surfaceBudget
    }
    return try develop(try frame.data(), sensor: sensor, region: region)
  }

  private static func sensorFrame(_ url: URL) throws -> (FlashRawFrame, Sensor) {
    try Task.checkCancellation()
    guard url.isFileURL, url.pathExtension.lowercased() == "arw" else {
      throw Calibration.Failure.unqualifiedSource
    }
    let source = try FlashRawSource.open(url)
    guard source.decoderVersion == "0.3.1", source.rawDetails == .bayerAHD else {
      throw Calibration.Failure.unqualifiedSource
    }
    let geometry = try source.sceneSensorSize()
    guard (2...16_384).contains(geometry.width), (2...16_384).contains(geometry.height),
          geometry.width * geometry.height <= 65_000_000 else { throw Calibration.Failure.invalidGeometry }
    let frame = try source.decode(output: .rawU16, backend: .automatic)
    let info = try frame.sceneBayerMetadata()
    let (r,g,b,g2) = info.white_balance
    let coefficients = withUnsafeBytes(of: info.xyz_to_camera) { Array($0.bindMemory(to: Float.self)) }
    let calibration = try Calibration(xyzToCamera: coefficients, whiteBalance: .init(r,g,b,g2))
    let sensor = try Sensor(width: frame.info.width, height: frame.info.height, orientation: frame.info.orientation,
      active: .init(info.active.0,info.active.1,info.active.2,info.active.3), crop: .init(info.crop.0,info.crop.1,info.crop.2,info.crop.3),
      colors: .init(info.colors.0,info.colors.1,info.colors.2,info.colors.3),
      black: .init(info.black.0,info.black.1,info.black.2,info.black.3),
      white: .init(info.white.0,info.white.1,info.white.2,info.white.3), calibration: calibration)
    return (frame, sensor)
  }

  /// A batch candidate still needs real RAW/calibration admission but no GPU surface before it is rendered.
  static func verifyCalibration(_ url: URL) throws {
    try autoreleasepool { _ = try sensorFrame(url) }
  }

  func develop(_ mosaic: Data, sensor: Sensor, region: MTLRegion? = nil) throws -> Result {
    try Task.checkCancellation()
    guard mosaic.count == sensor.width * sensor.height * MemoryLayout<UInt16>.stride else { throw Calibration.Failure.invalidMosaic }
    let fullWidth=Int(sensor.size.x), fullHeight=Int(sensor.size.y)
    let rect = region ?? MTLRegionMake2D(0, 0, fullWidth, fullHeight)
    let (x,y,width,height) = (rect.origin.x,rect.origin.y,rect.size.width,rect.size.height)
    guard rect.origin.z == 0, rect.size.depth == 1, x >= 0, y >= 0, width > 0, height > 0,
          width <= fullWidth, height <= fullHeight, x <= fullWidth-width, y <= fullHeight-height else {
      throw Calibration.Failure.invalidGeometry
    }

    func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, source: Bool = false) -> MTLTexture? {
      let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
      descriptor.storageMode=source ? .shared : .private
      descriptor.usage=source ? .shaderRead : [.shaderRead,.shaderWrite]
      return device.makeTexture(descriptor: descriptor)
    }
    guard let raw = texture(.r16Uint,sensor.width,sensor.height,source:true),
          let rgb = texture(.rgba32Float,width,height), let saturation = texture(.r8Uint,width,height),
          let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      throw Color.Failure.metalUnavailable
    }
    mosaic.withUnsafeBytes { bytes in
      raw.replace(region: MTLRegionMake2D(0,0,sensor.width,sensor.height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: sensor.width * MemoryLayout<UInt16>.stride)
    }
    let rows=sensor.calibration.rows
    var params=Parameters(active:sensor.active,crop:sensor.crop,colors:sensor.colors,
      output:.init(UInt32(x),UInt32(y),UInt32(sensor.orientation),0),black:sensor.black,white:sensor.white,
      red:rows.0,green:rows.1,blue:rows.2)
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(raw,index:0); encoder.setTexture(rgb,index:1); encoder.setTexture(saturation,index:2)
    encoder.setBytes(&params,length:MemoryLayout<Parameters>.stride,index:0)
    let lanes=pipeline.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),
      threadsPerThreadgroup:MTLSize(width:lanes,height:min(8,pipeline.maxTotalThreadsPerThreadgroup/lanes),depth:1))
    encoder.endEncoding()
    command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? Color.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    return Result(image:.init(texture:rgb,port:.working,origin:.init(x,y)),sensorSaturation:saturation)
  }

  private static let kernel = #"""
#include <metal_stdlib>
using namespace metal;
struct Params { uint4 active, crop, colors, output; float4 black, white, red, green, blue; };
uint2 bayer_sensor_pixel(uint2 pos, uint2 size, uint orientation) {
    uint x = pos.x, y = pos.y, w = size.x - 1, h = size.y - 1;
    switch (orientation) {
      case 2: return uint2(w-x,y); case 3: return uint2(w-x,h-y); case 4: return uint2(x,h-y);
      case 5: return uint2(y,x); case 6: return uint2(y,h-x); case 7: return uint2(w-y,h-x);
      case 8: return uint2(w-y,x); default: return pos;
    }
}
kernel void rmSceneBayerV1(texture2d<uint, access::read> raw [[texture(0)]],
                            texture2d<float, access::write> rgb [[texture(1)]],
                            texture2d<uint, access::write> saturation [[texture(2)]],
                            constant Params& p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    uint2 center = bayer_sensor_pixel(xy + p.output.xy, p.crop.zw, p.output.z) + p.crop.xy;
    uint ownPhase = ((center.y & 1) << 1) | (center.x & 1);
    uint ownColor = p.colors[ownPhase];
    float3 sum = 0;
    uint3 count = 0;
    uint saturated = 0;
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
      int2 neighbor = int2(center) + int2(x,y);
      if (any(neighbor < int2(p.active.xy)) || any(neighbor >= int2(p.active.xy + p.active.zw))) continue;
      uint phase = ((uint(neighbor.y) & 1) << 1) | (uint(neighbor.x) & 1);
      uint color = p.colors[phase];
      if (color == ownColor && (x != 0 || y != 0)) continue;
      float value = float(raw.read(uint2(neighbor)).r);
      sum[color] += (value - p.black[phase]) / (p.white[phase] - p.black[phase]);
      ++count[color];
      if (value >= p.white[phase]) saturated |= 1u << color;
    }
    float3 camera = sum / float3(count);
    float3 ap1 = float3(dot(p.red.xyz,camera),dot(p.green.xyz,camera),dot(p.blue.xyz,camera));
    rgb.write(float4(ap1,1),xy);
    saturation.write(uint4(saturated,0,0,0),xy);
}
"""#
}

package enum SceneWorkflowRawQualification {
  package static func verify(_ source: EditingSourceSnapshot) throws {
    try DevelopmentSceneRAWV1.verifyCalibration(source.sourceLocation)
  }
  package static func sharePreview(_ frame: DevelopmentScenePreviewFrameV1) throws -> CGImage {
    guard frame.target == .sdr709 else { throw DevelopmentError.invalidEncoding }
    let image = try DevelopmentSceneDeliveryServiceV1.linearSDRImage(frame.texture)
    let context = CIContext(mtlDevice: frame.texture.device)
    guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB) else { throw DevelopmentError.invalidEncoding }
    return result
  }
}
