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

  struct Mosaic {
    let sensor: Sensor
    let texture: MTLTexture
  }

  enum Sampling {
    case native(MTLRegion?)
    case fit(width: Int, height: Int)
  }

  private struct Parameters {
    let active, crop, colors, output: SIMD4<UInt32>
    let black, white, red, green, blue: SIMD4<Float>
  }
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let fitPipeline: MTLComputePipelineState
  private let photographicTile: MTLComputePipelineState

  init(device: MTLDevice) throws {
    guard let queue = device.makeCommandQueue() else { throw Color.Failure.metalUnavailable }
    let options = MTLCompileOptions()
    options.mathMode = .safe
    let library = try device.makeLibrary(source: Self.kernel, options: options)
    guard let function = library.makeFunction(name: "rmSceneBayerV1"),
          let fit = library.makeFunction(name: "rmSceneBayerFitV1"),
          let photo = library.makeFunction(name: "rmSceneBayerPhotoV1") else { throw Color.Failure.metalUnavailable }
    self.pipeline = try device.makeComputePipelineState(function: function)
    self.fitPipeline = try device.makeComputePipelineState(function: fit)
    self.photographicTile = try device.makeComputePipelineState(function: photo)
    self.device=device; self.queue=queue
  }

  func prepare(_ url: URL) throws -> Mosaic {
    let (frame, sensor) = try SceneDeliveryTrace.measure(.sensorFrame) { try Self.sensorFrame(url) }
    let data = try SceneDeliveryTrace.measure(.mosaicData) { try frame.data() }
    let mosaic = try SceneDeliveryTrace.measure(.mosaicUpload) { try upload(data, sensor: sensor) }
    SceneDeliveryTrace.sampleMemory(device: device)
    return mosaic
  }

  func decode(_ url: URL, region: MTLRegion? = nil) throws -> Result {
    try develop(prepare(url), sampling: .native(region))
  }

  private static func sensorFrame(_ url: URL) throws -> (FlashRawFrame, Sensor) {
    try Task.checkCancellation()
    guard url.isFileURL, url.pathExtension.lowercased() == "arw" else {
      throw Calibration.Failure.unqualifiedSource
    }
    let source = try FlashRawSource.open(url)
    guard source.decoderVersion == "0.3.1" else {
      throw FlashRawError.unavailable("Unsupported scene decoder version")
    }
    guard source.rawDetails == .bayerAHD else {
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

  func upload(_ mosaic: Data, sensor: Sensor) throws -> Mosaic {
    try Task.checkCancellation()
    guard mosaic.count == sensor.width * sensor.height * MemoryLayout<UInt16>.stride else { throw Calibration.Failure.invalidMosaic }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: sensor.width, height: sensor.height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let raw = device.makeTexture(descriptor: descriptor) else { throw Color.Failure.metalUnavailable }
    mosaic.withUnsafeBytes { bytes in
      raw.replace(region: MTLRegionMake2D(0, 0, sensor.width, sensor.height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: sensor.width * MemoryLayout<UInt16>.stride)
    }
    try Task.checkCancellation()
    return Mosaic(sensor: sensor, texture: raw)
  }

  func develop(_ raw: Mosaic, sampling: Sampling, maximumBytes: Int = .max) throws -> Result {
    try Task.checkCancellation()
    let sensor = raw.sensor
    let fullWidth=Int(sensor.size.x), fullHeight=Int(sensor.size.y)
    let rect: MTLRegion
    let selected: MTLComputePipelineState
    switch sampling {
    case .native(let region):
      rect = region ?? MTLRegionMake2D(0, 0, fullWidth, fullHeight)
      selected = pipeline
    case .fit(let width, let height):
      rect = MTLRegionMake2D(0, 0, width, height)
      selected = width == fullWidth && height == fullHeight ? pipeline : fitPipeline
    }
    let (x,y,width,height) = (rect.origin.x,rect.origin.y,rect.size.width,rect.size.height)
    guard rect.origin.z == 0, rect.size.depth == 1, x >= 0, y >= 0, width > 0, height > 0,
          width <= fullWidth, height <= fullHeight, x <= fullWidth-width, y <= fullHeight-height else {
      throw Calibration.Failure.invalidGeometry
    }

    func output(_ format: MTLPixelFormat) -> MTLTextureDescriptor {
      let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
      return descriptor
    }
    let colorDescriptor = output(.rgba32Float), saturationDescriptor = output(.r8Uint)
    let bytes = raw.texture.allocatedSize + device.heapTextureSizeAndAlign(descriptor: colorDescriptor).size
      + device.heapTextureSizeAndAlign(descriptor: saturationDescriptor).size
    guard bytes <= maximumBytes else { throw Failure.surfaceBudget }
    guard let rgb = device.makeTexture(descriptor: colorDescriptor), let saturation = device.makeTexture(descriptor: saturationDescriptor),
          let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      throw Color.Failure.metalUnavailable
    }
    let rows=sensor.calibration.rows
    var params=Parameters(active:sensor.active,crop:sensor.crop,colors:sensor.colors,
      output:.init(UInt32(x),UInt32(y),UInt32(sensor.orientation),0),black:sensor.black,white:sensor.white,
      red:rows.0,green:rows.1,blue:rows.2)
    encoder.setComputePipelineState(selected)
    encoder.setTexture(raw.texture,index:0); encoder.setTexture(rgb,index:1); encoder.setTexture(saturation,index:2)
    encoder.setBytes(&params,length:MemoryLayout<Parameters>.stride,index:0)
    let lanes=selected.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),
      threadsPerThreadgroup:MTLSize(width:lanes,height:min(8,selected.maxTotalThreadsPerThreadgroup/lanes),depth:1))
    encoder.endEncoding()
    command.commit()
    SceneDeliveryTrace.wait(command, host: .rawDevelopWait, gpu: .rawDevelopGPU)
    guard command.status == .completed else { throw command.error ?? Color.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    return Result(image:.init(texture:rgb,port:.working,origin:.init(x,y)),sensorSaturation:saturation)
  }

  /// Core Image asks for native rectangles in bottom-left coordinates. Texture row zero is the top row.
  func encodePhotographicTile(_ raw: Mosaic, region: CGRect, output: MTLTexture, command: MTLCommandBuffer) throws {
    let sensor = raw.sensor, dimensions = sensor.size
    let x = Int(region.minX), top = Int(dimensions.y) - Int(region.maxY)
    let width = Int(region.width), height = Int(region.height)
    guard command.device === device, output.device === device, output.pixelFormat == .rgba32Float,
          width > 0, height > 0, Int32(exactly: x) != nil, Int32(exactly: top) != nil,
          width <= output.width, height <= output.height, let encoder = command.makeComputeCommandEncoder() else {
      throw Color.Failure.invalidRegion
    }
    let coefficients = try Color.makeTransform(from: .working, to: .linearRec709).rows
    let camera = sensor.calibration.rows
    func converted(_ row: SIMD4<Float>) -> SIMD4<Float> { row.x * camera.0 + row.y * camera.1 + row.z * camera.2 }
    var p = Parameters(active: sensor.active, crop: sensor.crop, colors: sensor.colors,
      output: .init(UInt32(truncatingIfNeeded: x), UInt32(truncatingIfNeeded: top), UInt32(sensor.orientation), 0), black: sensor.black, white: sensor.white,
      red: converted(coefficients.0), green: converted(coefficients.1), blue: converted(coefficients.2))
    encoder.setComputePipelineState(photographicTile)
    encoder.setTexture(raw.texture, index: 0); encoder.setTexture(output, index: 1)
    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
    let lanes = photographicTile.threadExecutionWidth
    encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup:
      .init(width: lanes, height: min(8, photographicTile.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
    encoder.endEncoding()
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
struct BayerPixel { float3 ap1; uint saturated; };
BayerPixel bayer_pixel(texture2d<uint, access::read> raw, constant Params& p, uint2 xy) {
    uint2 center = bayer_sensor_pixel(xy, p.crop.zw, p.output.z) + p.crop.xy;
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
    return {ap1,saturated};
}
kernel void rmSceneBayerPhotoV1(texture2d<uint, access::read> raw [[texture(0)]],
                                texture2d<float, access::write> rgb [[texture(1)]],
                                constant Params& p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    int2 at = int2(xy) + as_type<int2>(p.output.xy);
    int2 size = int2(p.output.z < 5 ? p.crop.zw : p.crop.wz);
    if (any(at < 0) || any(at >= size)) { rgb.write(float4(0),xy); return; }
    rgb.write(float4(bayer_pixel(raw,p,uint2(at)).ap1,1),xy);
}
kernel void rmSceneBayerV1(texture2d<uint, access::read> raw [[texture(0)]],
                            texture2d<float, access::write> rgb [[texture(1)]],
                            texture2d<uint, access::write> saturation [[texture(2)]],
                            constant Params& p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    BayerPixel pixel = bayer_pixel(raw,p,xy+p.output.xy);
    rgb.write(float4(pixel.ap1,1),xy);
    saturation.write(uint4(pixel.saturated,0,0,0),xy);
}
// Integrate precisely the covered native pixels in signed AP1. The sensor overlay is a
// point measurement at the grid cell's center, independently of its area-averaged color.
kernel void rmSceneBayerFitV1(texture2d<uint, access::read> raw [[texture(0)]],
                               texture2d<float, access::write> rgb [[texture(1)]],
                               texture2d<uint, access::write> saturation [[texture(2)]],
                               constant Params& p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    uint2 full = p.output.z < 5 ? p.crop.zw : p.crop.wz;
    float2 size = float2(rgb.get_width(),rgb.get_height()), scale = float2(full)/size;
    float2 low = float2(xy)*scale, high = min(float2(xy+1)*scale,float2(full));
    uint2 first = uint2(floor(low)), limit = uint2(ceil(high));
    uint2 center = min(uint2((float2(xy)+0.5f)*float2(full)/size),full-1);
    float3 sum = 0;
    float area = 0;
    uint bits = 0;
    for (uint y=first.y; y<limit.y; ++y) {
        float wy=min(float(y+1),high.y)-max(float(y),low.y);
        for (uint x=first.x; x<limit.x; ++x) {
            uint2 at=uint2(x,y);
            BayerPixel pixel=bayer_pixel(raw,p,at);
            float w=wy*(min(float(x+1),high.x)-max(float(x),low.x));
            sum+=pixel.ap1*w;
            area+=w;
            if (all(at==center)) bits=pixel.saturated;
        }
    }
    rgb.write(float4(sum/area,1),xy);
    saturation.write(uint4(bits,0,0,0),xy);
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
