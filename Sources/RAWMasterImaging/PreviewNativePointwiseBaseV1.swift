import Foundation
import CoreImage
import ImageIO
import CryptoKit
import RAWMasterCore

/// Separate closed native identities share the SAME existing pool, LRU and allocation budget.
/// A requested recipe fingerprint is never substituted for the actual decoder/default identity.
struct PreviewNativePointwiseBaseDescriptorV1: Hashable, Encodable {
  enum Source: Hashable, Encodable {
    case rawDefaults(originalDefaults: String)
    case imageOrientedDecode(colorProfile: String)
  }
  let source: Source
  let sourceKey, verifiedContentID: String
  let captureID: UUID
  let generation: UInt64
  let stamp: PreviewNativePointwiseStampV1
  let decoder, os, contract: String
  let deviceRegistryID:UInt64
  let orientation, width, height: Int
  let extentXBits, extentYBits: UInt64
  let sourceDepth:Int?
  let originalNoiseFingerprint: String
  static let contract = "native-pointwise-defaults-v1/F32-premul-linear-sRGB/scale1/draftfalse/whole/context512-cachefalse"
  func fingerprint() throws -> String { try EditingFingerprint.of(self) }
}
struct PreviewNativePointwiseStampV1: Hashable, Encodable {
  let device: Int32, inode: UInt64, size: Int64
  let seconds, nanos, changedSeconds, changedNanos: Int
  init(_ s: PreviewFileStamp) {
    device=s.device;inode=s.inode;size=s.size;seconds=s.seconds;nanos=s.nanoseconds
    changedSeconds=s.changedSeconds;changedNanos=s.changedNanoseconds
  }
}

enum PreviewNativePointwiseBaseV1 {
  /// Metadata/provider construction, no pixel readback. Failure disables only the new mode.
  struct ImageMetadata { let profile:String;let depth:Int }
  static func imageProfile(_ url:URL)->String? { imageMetadata(url)?.profile }
  static func imageMetadata(_ url: URL) -> ImageMetadata? {
    guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),
      let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary),
      let space=image.colorSpace else { return nil }
    let name=(space.name as String?) ?? "unnamed"
    if let profile=space.copyICCData() as Data? {
      guard profile.count <= 32768 else { return nil } // The closed route's 64KiB metadata reservation includes this temporary.
      return .init(profile:"decoded-ICC-present:"+SHA256.hash(data:profile).map{String(format:"%02x",$0)}.joined()+":"+name,depth:image.bitsPerComponent)
    }
    return .init(profile:"decoded-ICC-absent:"+name+":model-\(space.model.rawValue)",depth:image.bitsPerComponent)
  }
  static func noiseFingerprint(_ native: PreviewNativeSource) throws -> String {
    guard let n=native.noiseReductionFacts.raw else { return "image-no-RAW-NR" }
    struct Bits: Encodable {
      let luminance, color, detail: UInt32
      let lSupported, cSupported, dSupported: Bool
    }
    return try EditingFingerprint.of(Bits(luminance:n.defaultLuminanceNoise.bitPattern,
      color:n.defaultColorNoise.bitPattern,detail:n.defaultDetail.bitPattern,
      lSupported:n.luminanceNoiseSupported,cSupported:n.colorNoiseSupported,dSupported:n.detailSupported))
  }
  static func descriptor(_ native: PreviewNativeSource,sourceKey: String,generation: UInt64,
                         verifiedContentID: String) throws -> PreviewNativePointwiseBaseDescriptorV1 {
    guard let deviceID=native.nativePointwiseDeviceID else { throw PreviewPresentationError.unsupported }
    let source: PreviewNativePointwiseBaseDescriptorV1.Source
    if native.hasRAWFilter {
      guard let defaults=native.originalNativeDefaultsFingerprint else { throw PreviewPresentationError.unsupported }
      source = .rawDefaults(originalDefaults:defaults)
    } else {
      guard let profile=native.nativePointwiseImageICCIdentity else { throw PreviewPresentationError.unsupported }
      source = .imageOrientedDecode(colorProfile:profile)
    }
    return .init(source:source,sourceKey:sourceKey,verifiedContentID:verifiedContentID,captureID:native.captureID,
      generation:generation,stamp:.init(native.captureStamp),decoder:native.decoder,
      os:ProcessInfo.processInfo.operatingSystemVersionString,contract:PreviewNativePointwiseBaseDescriptorV1.contract,deviceRegistryID:deviceID,
      orientation:native.originalEXIFOrientation,width:Int(native.nativeSize.width),height:Int(native.nativeSize.height),
      extentXBits:Double(native.orientedNativeExtent.minX).bitPattern,extentYBits:Double(native.orientedNativeExtent.minY).bitPattern,
      sourceDepth:native.nativePointwiseImageDepth,originalNoiseFingerprint:try noiseFingerprint(native))
  }
  /// Only fresh native defaults. EV/WB/NR edits are excluded by eligibility, not approximated.
  static func input(_ native: PreviewNativeSource,descriptor: PreviewNativePointwiseBaseDescriptorV1) throws -> CIImage {
    try native.validateCaptureAuthority()
    guard descriptor.captureID==native.captureID,descriptor.stamp == .init(native.captureStamp),
      descriptor.decoder==native.decoder,descriptor.originalNoiseFingerprint == (try noiseFingerprint(native)) else { throw DevelopmentPreviewError.sourceInvalidated }
    let image: CIImage
    switch descriptor.source {
    case .rawDefaults(let defaults):
      guard let raw=CIRAWFilter(imageURL:native.capture),raw.decoderVersion.rawValue==descriptor.decoder,
        try DevelopmentRendererV3.decoderDefaultsFingerprint(raw)==defaults else { throw DevelopmentPreviewError.sourceInvalidated }
      // configure's actual Float+0 readback and unsupported checks remain authoritative.
      // Its asShot branch does NOT write TT to this fresh decoder; NR zero leaves defaults.
      let parameters=try DevelopmentRendererV3.NativeParameters(DevelopmentAdjustmentsV3(),
        noiseDefaults:DevelopmentRendererV3.noiseDefaults(raw),originalDefaultsFingerprint:defaults)
      guard parameters.exposure.bitPattern==Float(0).bitPattern else { throw DevelopmentV3Error.unsupportedNativeParameters }
      try DevelopmentRendererV3.configure(raw,parameters:parameters)
      guard let output=raw.outputImage,Int(raw.orientation.rawValue)==descriptor.orientation else { throw DevelopmentError.unreadable }
      image=output
    case .imageOrientedDecode(let profile):
      guard let metadata=imageMetadata(native.capture),metadata.profile==profile,metadata.depth==descriptor.sourceDepth,
        let output=CIImage(contentsOf:native.capture,options:[.applyOrientationProperty:true]) else { throw DevelopmentPreviewError.sourceInvalidated }
      image=output
    }
    guard image.extent==CGRect(x:0,y:0,width:descriptor.width,height:descriptor.height),
      image.extent==native.orientedNativeExtent else { throw PreviewPresentationError.allocationProtocol }
    return image
  }
}
