import Foundation
import CoreImage
import CoreVideo
import CryptoKit
import RAWMasterCore

/// A preview-only engineering certificate, not a proof of an arbitrary CI optimizer.
/// Source alpha1 is insufficient until the nonzero sampler footprint is inside this owner.
enum PreviewNativePointwiseCertificateV1 {
  static let version = "point-saturation-alpha1-abs2p20-f32-v1"
  static let samplerVersion = "identity-native-or-inverse-FIT-positive-linear/envelope-v1"
  static let pointSourceSHA256 = "775c7009e4a86947f23d2f4b207c261ee578a416585e85133c874d4b261386db"
  static let bound: Float = 0x1p20
  struct Input {
    let owner: UUID
    let authority: String
    let eligible: Bool
    let pixels: Int
    let maximumAbsoluteRGB: Float
  }
  struct Sampler: Equatable {
    let owner: UUID
    let authority: String
    let grid: Grid
    let device: UInt64
    let pointSHA256, witnessSHA256, samplerABI, os: String
    let optionsVersion: String
  }
  struct Grid: Equatable {
    let width, height, nativeWidth, nativeHeight: Int
    let scale: Double
    /// Conservative source-coordinate error, NOT a tolerance permitting outside samples.
    let roundoffBound: Double
    let edgeInset: Double
    var envelopeClosed: Bool { scale == 1 || roundoffBound < edgeInset }
    var extent: CGRect { .init(x:0,y:0,width:width,height:height) }
  }
  static func grid(width: Int, height: Int) throws -> Grid {
    guard width > 0, height > 0,
      width <= DevelopmentLocalEditLimits.maximumSourceDimension,
      height <= DevelopmentLocalEditLimits.maximumSourceDimension else { throw PreviewPresentationError.invalidLayout }
    let long = max(width,height), scale = min(1,2400.0 / Double(long))
    let w = Double(width)*scale, h = Double(height)*scale
    // Use the ACTUAL CGFloat materializer arithmetic. No integralize or alternative viewport.
    guard w.isFinite, h.isFinite, w == floor(w), h == floor(h), w >= 1, h >= 1,
      w <= 2400, h <= 2400 else { throw PreviewPresentationError.unsupported }
    let error: Double
    if scale == 1 {
      // No affine is installed by the canonical materializer in this case. All integer+.5
      // source centers are exactly representable as Float in the Core dimension domain.
      guard Double(long)+0.5 < 0x1p23 else { throw PreviewPresentationError.unsupported }
      error = 0
    } else {
      // Ordinary RGBAf affine/sampler ABI premise (cf3b proof): one scale/inverse map,
      // at most 32 effective scalar roundings/casts. The closed graph has <=3 zero
      // origin/identity affine nodes (<=12 2D coordinate ops), one inverse FIT
      // division, sampler normalization/texel conversion and tile-origin adds/casts;
      // 32 conservatively covers these standard affine/sampler primitives. This is
      // an API arithmetic-error premise, NOT an observed optimizer instruction count.
      // No arbitrary CI transform/filter is admitted under this bound. gamma_32 bounds chained Float
      // add/mul/div rounding, including a reciprocal and a rounded center. Using the
      // maximum NATIVE coordinate (not 2400) also bounds cancellation/ROI coordinates.
      // The actual Double scale's Float coefficient quantization is charged separately.
      // There is no subnormal coordinate/coefficient in this bounded dimension domain.
      let u: Double = 0x1p-24
      let gamma = (32*u)/(1-32*u)
      let sf = Double(Float(scale))
      let coefficientRelative = abs(sf-scale)/scale
      error = ((Double(long)+1)*gamma + Double(long)*coefficientRelative/(1-u)).nextUp
    }
    // For each axis, inverse FIT centers are [.5/s,N-.5/s]. Native point centers
    // k+.5 or a fused point at inverse FIT coordinates have only nonnegative linear
    // weights inside [0,N-1]. Default sampler is linear (CISampler.h), black wrap.
    // The end's zero-weight outside neighbor is not an input. No Lanczos/negative lobes.
    // If rounding cannot fit STRICTLY inside this margin we retain full checks instead.
    return .init(width:Int(w),height:Int(h),nativeWidth:width,nativeHeight:height,scale:scale,
      roundoffBound:error,edgeInset:scale == 1 ? 0:0.5/scale-0.5)
  }
  static func scan(address: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int,
                   owner: UUID, authority: String) throws -> Input {
    guard width > 0,height > 0,rowBytes >= width*16 else { throw PreviewPresentationError.invalidLayout }
    var eligible = true, maximum: Float = 0
    for y in 0..<height { for x in 0..<width {
      let p = address.loadUnaligned(fromByteOffset:y*rowBytes+x*16,as:SIMD4<Float>.self)
      guard p.x.isFinite,p.y.isFinite,p.z.isFinite,p.w.isFinite else { throw DevelopmentError.invalidEncoding }
      let m = max(abs(p.x),max(abs(p.y),abs(p.z)))
      maximum = max(maximum,m)
      if p.w.bitPattern != Float(1).bitPattern || m > bound { eligible = false }
    }}
    return .init(owner:owner,authority:authority,eligible:eligible,pixels:width*height,maximumAbsoluteRGB:maximum)
  }
  static func poison(address: UnsafeMutableRawPointer,width: Int,height: Int,rowBytes: Int) {
    // Only logical pixels. No full native Data/array or inspection of padding as pixels.
    let poison = SIMD4<Float>(repeating:.nan)
    for y in 0..<height { for x in 0..<width {
      address.storeBytes(of:poison,toByteOffset:y*rowBytes+x*16,as:SIMD4<Float>.self)
    }}
  }
  static let witnessSource = """
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmNativePointwiseWitness(sampler src) { return src.sample(src.coord()); }
}}
"""
  static var witnessSHA256: String { SHA256.hash(data:Data(witnessSource.utf8)).map { String(format:"%02x",$0) }.joined() }
  private static let witness: Result<CIKernel,Error> = Result {
    guard let k = try CIKernel.kernels(withMetalString:witnessSource).first else { throw DevelopmentError.unsupportedEngine }
    return k
  }
  /// This identity graph MAY be optimized away. Its PASS is only an actual veto check,
  /// never a same-grid/point-kernel equivalence premise or a repair of an open envelope.
  static func vetoImage(_ image: CIImage) throws -> CIImage {
    guard let result = try witness.get().apply(extent:image.extent,roiCallback:{ _,r in r },arguments:[image]) else { throw DevelopmentV3Error.invalidGraph }
    return result
  }
}

/// Independent c82e common-point arithmetic domain. The immutable Input summary
/// certifies source bytes only (alpha bit1, absRGB<=2^20), not any recipe's arithmetic.
/// All original MSL intermediates are <2^120 under the reviewed normal RGBAf API
/// premise. This does not extend the old saturation proof or certify Curves/Levels.
enum PreviewNativePointwiseCertificateV2 {
  static let version = "point-common-LCBW-grain0-alpha1-abs2p20-f32-v2.1"
  static let proofDocumentSHA256 = "c82e984c3d008cb911975286fe4fcfe52b140e70b4acc28294c2c7167169de74"
  static let routeVersion = "native-F32-common-point-certificate-v2.1/public-canonical-FIT-target"
  static let fullValidationVersion = "native-F32-common-point-v2.1/full-native-validation/public-canonical-FIT-target"
  static let samplerVersion = "common-LCBW-grain0-native-or-inverse-FIT-positive-linear/envelope-v2.1"
  struct Binding: Encodable, Equatable {
    let proofID: String
    let recipeFingerprint: String
    let pointwiseActive: Bool
    /// Exact original upload order: light, color, BW, flags. Includes disabled
    /// parameters, BW default .5, signed zero and Double-nonzero -> Float-zero.
    let floatBits: [UInt32]
    init(_ recipe: DevelopmentRecipe) throws {
      try recipe.validate()
      guard let p=recipe.adjustmentsV3 else { throw PreviewPresentationError.unsupported }
      proofID=PreviewNativePointwiseCertificateV2.version;recipeFingerprint=try EditingFingerprint.of(recipe)
      pointwiseActive=DevelopmentColorEngineV3.pointwiseActive(p)
      let l=p.light,c=p.color,b=p.blackAndWhite
      let values:[Double]=[l.brightness,l.contrast,l.blackPoint,0,c.saturation,c.vibrance,c.cast,0,
        b.intensity,b.neutrals,b.tone,b.grain,l.enabled ? 1:0,c.enabled ? 1:0,b.enabled ? 1:0,0]
      floatBits=values.map { Float($0).bitPattern }
    }
    func fingerprint() throws -> String { try EditingFingerprint.of(self) }
  }
  static func domainReason(_ recipe: DevelopmentRecipe,size: CGSize) throws -> PreviewNativePointwiseV1.Reason? {
    try recipe.validate()
    guard var p=recipe.adjustmentsV3,recipe.schemaVersion==3 else { return .recipe }
    // Full original typed validation above bounds every stored L/C/BW scalar, even
    // when disabled. Spatial Light/native EV are excluded by ACTUAL fields, not flags.
    // Arithmetic finiteness of grain was proven, but its public FIT pixels failed
    // strict qualification. Any STORED nonzero value is canonical-only, even when
    // disabled or rounded to Float zero. Signed Double zero remains zero.
    guard p.blackAndWhite.grain==0 else { return .grainCanonical }
    guard p.light.brilliance==0,p.light.exposure==0,p.light.highlights==0,p.light.shadows==0 else { return .recipe }
    p.light=DevelopmentLightV3();p.color=DevelopmentColorV3();p.blackAndWhite=DevelopmentBlackAndWhiteV3()
    // Reuse only the exact fresh-suffix/neutral-legacy/identity projection checks.
    // No adjustment payload or actual recipe FP is rewritten.
    return try PreviewNativePointwiseV1.saturationDomainReason(.init(adjustmentsV3:p),size:size)
  }
  static func binding(_ recipe: DevelopmentRecipe,size: CGSize) throws -> Binding? {
    // Old sat-v1 wins, including all of its exact output key/version bytes.
    if try PreviewNativePointwiseV1.saturationDomainReason(recipe,size:size)==nil { return nil }
    guard try domainReason(recipe,size:size)==nil else { return nil }
    return try Binding(recipe)
  }
  static func samplerEnvelopeClosed(_ grid: PreviewNativePointwiseCertificateV1.Grid) -> Bool {
    // The new arithmetic bound is NOT borrowed from sat-v1. Only the same
    // coordinate API is shared: identity nodes + one FIT affine + positive linear
    // sampling. Re-evaluate its conservative Float gamma32/actual-scale bound here.
    // BW uses these coordinates only in floor->int32->defined uint hashing; its
    // source dimension <=1e6 keeps the conversion in range. It adds no sampler.
    guard grid.nativeWidth>0,grid.nativeHeight>0,
      max(grid.nativeWidth,grid.nativeHeight)<=DevelopmentLocalEditLimits.maximumSourceDimension,
      grid.width>0,grid.height>0,grid.width<=2400,grid.height<=2400,
      grid.scale>0,grid.scale<=1 else { return false }
    let n=Double(max(grid.nativeWidth,grid.nativeHeight))
    guard Double(grid.nativeWidth)*grid.scale==Double(grid.width),
      Double(grid.nativeHeight)*grid.scale==Double(grid.height) else { return false }
    if grid.scale==1 { return grid.roundoffBound==0 && n+0.5<0x1p23 }
    let u:Double=0x1p-24,gamma=(32*u)/(1-32*u)
    let coefficientRelative=abs(Double(Float(grid.scale))-grid.scale)/grid.scale
    let bound=((n+1)*gamma+n*coefficientRelative/(1-u)).nextUp
    let inset=0.5/grid.scale-0.5
    return bound.isFinite && bound<inset && grid.roundoffBound==bound && grid.edgeInset==inset
  }
}

/// The compact cold guard is charged to the existing SHARED presentation operation.
/// CV/IOSurface alias one allocation. The GPU-accessible CV surface is not reported as GPU0.
final class PreviewNativePointwiseGuardV1 {
  private var storage: RawBaseStorage?
  private let ticket: PreviewPresentationReservation
  init(grid: PreviewNativePointwiseCertificateV1.Grid,ticket: PreviewPresentationReservation) throws {
    self.ticket = ticket
    do {
      try ticket.requireOpenAdmission()
      let owner = try RawBaseStorage(width:grid.width,height:grid.height)
      storage = owner
      try ticket.registerActualAllocation(bytes:owner.allocationBytes)
    } catch { storage = nil;ticket.releaseAfterStorageReleased();throw error }
  }
  func veto(_ image: CIImage,context: CIContext,check: () throws -> Void) throws -> Bool {
    guard let storage else { throw PreviewPresentationError.closed }
    try check();try ticket.requireOpenAdmission()
    try storage.fill(image,context:context,checkpoint:{ _ in try check() },pointwiseAuthority:"cold-witness-veto")
    return storage.pointwiseInputCertificate?.eligible == true
  }
  deinit { storage = nil;ticket.releaseAfterStorageReleased() }
}
