import CoreGraphics
import Foundation
import ImageIO
import Metal

final class DevelopmentSceneAVIFV1 {
  enum Failure: Error, Equatable { case unsupportedEncoder, invalidInput, invalidPixel, invalidContainer }
  typealias MetalFailure = DevelopmentSceneColorV1.Failure

  struct Signal: Equatable {
    let primaries, transfer, matrix: Int
    let bitDepth: Int
    let fullRange: Bool
  }

  struct Encoded {
    let bytes: Data
    let signal: Signal
    let width, height: Int
    let referenceWhiteNits = 100
    let peakNits = 1000
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private static let identifier = "public.avif" as CFString

  init(device: MTLDevice) throws {
    guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(Self.identifier as String) == true else {
      throw Failure.unsupportedEncoder
    }
    let options=MTLCompileOptions(); options.mathMode = .safe
    let library=try device.makeLibrary(source:Self.kernel,options:options)
    guard let function=library.makeFunction(name:"rmScenePQRGB16V1"), let queue=device.makeCommandQueue() else {
      throw MetalFailure.metalUnavailable
    }
    self.pipeline=try device.makeComputePipelineState(function:function)
    self.queue=queue; self.device=device
  }

  func encode(_ image: DevelopmentSceneOutputV1.DisplayImage, quality: Double = 0.95) throws -> Encoded {
    try Task.checkCancellation()
    let source=image.texture
    guard image.target == .hdr2020, source.device === device, source.pixelFormat == .rgba32Float,
          quality.isFinite, (0...1).contains(quality), source.width*source.height <= 65_000_000 else { throw Failure.invalidInput }
    let row=source.width * 8
    let length=row * source.height
    guard let pixels=device.makeBuffer(length:length,options:.storageModeShared),
          let flag=device.makeBuffer(length:4,options:.storageModeShared),
          let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else {
      throw MetalFailure.metalUnavailable
    }
    let invalid=flag.contents().bindMemory(to:UInt32.self,capacity:1); invalid.pointee=0
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source,index:0); encoder.setBuffer(pixels,offset:0,index:0); encoder.setBuffer(flag,offset:0,index:1)
    let lanes=pipeline.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width:source.width,height:source.height,depth:1),
      threadsPerThreadgroup:MTLSize(width:lanes,height:min(8,pipeline.maxTotalThreadsPerThreadgroup/lanes),depth:1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? MetalFailure.gpuExecutionFailed }
    try Task.checkCancellation()
    guard invalid.pointee == 0 else { throw Failure.invalidPixel }
    let data=Data(bytesNoCopy:pixels.contents(),count:length,deallocator:.custom { [pixels] _,_ in _=pixels })
    let destination=NSMutableData()
    guard let color=CGColorSpace(name:CGColorSpace.itur_2100_PQ),
          let provider=CGDataProvider(data:data as CFData),
          let bitmap=CGImage(width:source.width,height:source.height,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:row,
            space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
          let encoder=CGImageDestinationCreateWithData(destination,Self.identifier,1,nil) else { throw Failure.unsupportedEncoder }
    CGImageDestinationAddImage(encoder,bitmap,[kCGImageDestinationLossyCompressionQuality:quality,kCGImagePropertyDepth:10] as CFDictionary)
    guard CGImageDestinationFinalize(encoder) else { throw Failure.unsupportedEncoder }
    try Task.checkCancellation()
    let encoded=destination as Data
    let signal=try Self.readSignal(encoded)
    guard let decoded=CGImageSourceCreateWithData(encoded as CFData,nil), CGImageSourceGetCount(decoded) == 1,
          let props=CGImageSourceCopyPropertiesAtIndex(decoded,0,nil) as? [CFString:Any],
          props[kCGImagePropertyPixelWidth] as? Int == source.width,
          props[kCGImagePropertyPixelHeight] as? Int == source.height else { throw Failure.invalidContainer }
    return Encoded(bytes:encoded,signal:signal,width:source.width,height:source.height)
  }

  // These item properties are required; a successful ImageIO call alone is not an HDR receipt.
  static func readSignal(_ data: Data) throws -> Signal { try readProperties(data).signal }

  /// ImageIO can fill `clli` with defaults. Until picture light levels are measured,
  /// leave both bounds unspecified (AVIF uses 0 for no upper bound).
  static func leavingLightLevelsUnspecified(_ data: Data) throws -> Data {
    guard let bounds = try readProperties(data).lightLevels else { return data }
    var result = data
    let range = (result.startIndex + bounds.lowerBound)..<(result.startIndex + bounds.upperBound)
    result.replaceSubrange(range, with: [UInt8](repeating: 0, count: 4))
    return result
  }

  static func lightLevels(_ data: Data) throws -> [Int]? {
    guard let offset = try readProperties(data).lightLevels?.lowerBound else { return nil }
    let i = data.startIndex + offset
    return [Int(data[i]) << 8 | Int(data[i + 1]), Int(data[i + 2]) << 8 | Int(data[i + 3])]
  }

  private static func readProperties(_ data: Data) throws -> (signal: Signal, lightLevels: Range<Int>?) {
    try data.withUnsafeBytes { bytes in
      struct Box { let tag: String; let payload: Range<Int> }
      func boxes(_ range: Range<Int>) throws -> [Box] {
        var pos=range.lowerBound, result=[Box]()
        while pos < range.upperBound {
          let available=range.upperBound-pos
          guard available >= 8, result.count < 256 else { throw Failure.invalidContainer }
          let size=(0..<4).reduce(UInt64(0)){ ($0 << 8) | UInt64(bytes[pos+$1]) }
          let tag=String(decoding:bytes[pos+4..<pos+8],as:UTF8.self)
          var header=8, length=size
          if size == 1 {
            guard available >= 16 else { throw Failure.invalidContainer }
            header=16; length=(8..<16).reduce(UInt64(0)){ ($0 << 8) | UInt64(bytes[pos+$1]) }
          } else if size == 0 { length=UInt64(available) }
          guard length >= header, length <= available else { throw Failure.invalidContainer }
          result.append(Box(tag:tag,payload:(pos+header)..<(pos+Int(length))))
          pos+=Int(length)
        }
        return result
      }
      func only(_ tag: String,_ boxes: [Box]) throws -> Range<Int> {
        let found=boxes.filter{$0.tag==tag}
        guard found.count == 1 else { throw Failure.invalidContainer }
        return found[0].payload
      }
      let outer=try boxes(0..<bytes.count)
      let brand=try only("ftyp",outer)
      let meta=try only("meta",outer)
      guard brand.count>=8, String(decoding:bytes[brand.prefix(4)],as:UTF8.self) == "avif", meta.count>=4 else {
        throw Failure.invalidContainer
      }
      let iprp=try only("iprp",boxes(meta.dropFirst(4)))
      let properties=try boxes(only("ipco",boxes(iprp)))
      let color=try only("colr",properties), pixels=try only("pixi",properties), av1=try only("av1C",properties)
      let p=color.lowerBound, q=pixels.lowerBound, a=av1.lowerBound
      guard color.count == 11, String(decoding:bytes[color.prefix(4)],as:UTF8.self) == "nclx",
            pixels.count == 8, bytes[q+4] == 3, (5...7).allSatisfy({bytes[q+$0] == 10}),
            av1.count >= 4, bytes[a] == 0x81, (bytes[a+2] & 0x60) == 0x40 else { throw Failure.invalidContainer }
      func u16(_ i: Int) -> Int { Int(bytes[p+i]) << 8 | Int(bytes[p+i+1]) }
      let signal=Signal(primaries:u16(4),transfer:u16(6),matrix:u16(8),bitDepth:10,fullRange:bytes[p+10] == 128)
      guard signal.primaries == 9, signal.transfer == 16, [1,9].contains(signal.matrix), signal.fullRange else { throw Failure.invalidContainer }
      let light = properties.filter { $0.tag == "clli" }
      guard light.count <= 1, light.first.map({ $0.payload.count == 4 }) ?? true else { throw Failure.invalidContainer }
      return (signal, light.first?.payload)
    }
  }

  private static let kernel = #"""
#include <metal_stdlib>
using namespace metal;
kernel void rmScenePQRGB16V1(texture2d<float,access::read> input [[texture(0)]], device ushort4* output [[buffer(0)]],
                             device atomic_uint& invalid [[buffer(1)]], uint2 xy [[thread_position_in_grid]]) {
  float4 p=input.read(xy);
  if (!all(isfinite(p)) || p.a != 1 || any(p.rgb < 0) || any(p.rgb > 10)) {
    atomic_store_explicit(&invalid,1,memory_order_relaxed); return;
  }
  float3 v=pow(p.rgb / 100.0f,2610.0f/16384.0f);
  float3 pq=pow((3424.0f/4096.0f+2413.0f/128.0f*v)/(1.0f+2392.0f/128.0f*v),2523.0f/32.0f);
  output[xy.y*input.get_width()+xy.x]=ushort4(ushort3(rint(pq*65535.0f)),65535);
}
"""#
}
