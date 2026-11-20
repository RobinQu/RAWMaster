import Foundation
import Metal
import RAWMasterCore

/// Thumbnail-only scope. Never use a consumer-wide cancel to retire this registration.
public struct DevelopmentThumbnailRegistration: Hashable, Sendable {
  public let registrationID: UUID
  public let operationID: UUID
  public let visibleGeneration: UInt64
  public init(registrationID: UUID = UUID(), operationID: UUID = UUID(), visibleGeneration: UInt64) {
    self.registrationID=registrationID;self.operationID=operationID;self.visibleGeneration=visibleGeneration
  }
}
public enum DevelopmentThumbnailKind: Equatable, Sendable {
  case summary(DevelopmentAdjustmentID)
  case filters
  public var count: Int { if case .filters = self { return 10 };return 5 }
}
public enum DevelopmentThumbnailTargetV1: String, Sendable { case summary128, filters192
  public var maximumPixel: Int { self == .summary128 ? 128:192 }
}
public enum DevelopmentThumbnailPresentationMode: String, Sendable { case texture, managedImage }
public enum DevelopmentThumbnailBasis: String,Sendable {case settledFit,currentCanonical}
public enum DevelopmentThumbnailError: Error, Equatable, Sendable {
  case invalidRequest, unsupportedGraph, awaitingSource, budgetUnavailable
  case superseded, cancelled, closed, staleSource, invalidLease, unavailableDevice, invalidEncoding
}
public struct DevelopmentThumbnailProgress: Equatable, Sendable {
  public let registration: DevelopmentThumbnailRegistration
  public let completed: Int
  public let total: Int
  public init(registration: DevelopmentThumbnailRegistration, completed: Int, total: Int) {
    self.registration=registration;self.completed=completed;self.total=total
  }
}
public struct DevelopmentThumbnailRequest: Sendable {
  public let registration: DevelopmentThumbnailRegistration
  public let preview: DevelopmentPreviewRequest
  public let expectedRecipeFingerprint: String
  public let presentedRecipeFingerprint: String
  public let kind: DevelopmentThumbnailKind
  public let target: DevelopmentThumbnailTargetV1
  public let contractVersion: Int
  public let presentationMode: DevelopmentThumbnailPresentationMode
  public let basis:DevelopmentThumbnailBasis
  public let expectedPhotoFilterResourceVersion:String?
  public init(registration: DevelopmentThumbnailRegistration, preview: DevelopmentPreviewRequest,
              expectedRecipeFingerprint: String, presentedRecipeFingerprint: String? = nil,
              kind: DevelopmentThumbnailKind, target: DevelopmentThumbnailTargetV1, contractVersion: Int = 1,
              presentationMode: DevelopmentThumbnailPresentationMode = .texture,basis:DevelopmentThumbnailBasis = .settledFit,
              expectedPhotoFilterResourceVersion:String? = nil) {
    self.registration=registration;self.preview=preview;self.expectedRecipeFingerprint=expectedRecipeFingerprint
    self.presentedRecipeFingerprint=presentedRecipeFingerprint ?? expectedRecipeFingerprint
    self.kind=kind;self.target=target;self.contractVersion=contractVersion;self.presentationMode=presentationMode
    self.basis=basis;self.expectedPhotoFilterResourceVersion=expectedPhotoFilterResourceVersion
  }
  func validate() throws {
    try preview.recipe.validate()
    guard registration.visibleGeneration>0,contractVersion==1,preview.role == .primary,
      preview.recipe.schemaVersion==3,
      (basis == .settledFit ? preview.quality != .detail:(preview.quality == .settled || (preview.quality == .detail && preview.viewport.maxPixel==0))),
      EditingFingerprint.isSHA256(expectedRecipeFingerprint),EditingFingerprint.isSHA256(presentedRecipeFingerprint),
      expectedRecipeFingerprint == (try EditingFingerprint.of(preview.recipe)) else { throw DevelopmentThumbnailError.invalidRequest }
    switch kind {
    case .summary(let group):
      guard [.light,.color,.blackAndWhite].contains(group),target == .summary128 else { throw DevelopmentThumbnailError.invalidRequest }
    case .filters: guard target == .filters192 else { throw DevelopmentThumbnailError.invalidRequest }
    }
  }
}
/// Exact physical allocation charge, including padding. Shared CPU/Metal aliases count once in union.
public struct DevelopmentThumbnailAllocation: Equatable, Sendable {
  public let allocationID: UUID
  public let residentCPUBytes: Int
  public let residentGPUBytes: Int
  public let unionBytes: Int
  public let bytesPerRow: Int
}
public struct DevelopmentThumbnailTileDescriptor: Sendable {
  public let index: Int
  public let summaryAmount: Double?
  public let filter: DevelopmentPhotoFilterV3?
  public let actualRecipe: DevelopmentRecipe
  public let actualRecipeFingerprint: String
  public let width: Int
  public let height: Int
  public let allocation: DevelopmentThumbnailAllocation
  public let storageFormat: String
  public let destinationColorSpace: String
  public let destinationICCProfileSHA256: String
  public let alphaPolicy: String
}
public struct DevelopmentThumbnailSetDescriptor: Sendable {
  public let registration: DevelopmentThumbnailRegistration
  public let actualRequest: DevelopmentPreviewRequest
  public let sourceBinding: DevelopmentLocalEditSourceBinding
  public let expectedRecipeFingerprint: String
  public let presentedRecipeFingerprint: String
  public let kind: DevelopmentThumbnailKind
  public let target: DevelopmentThumbnailTargetV1
  public let contractVersion: Int
  public let pipelineVersion: String
  public let proxyInputFingerprint: String
  public let proxyWidth: Int
  public let proxyHeight: Int
  public let proxyEncoding: String
  public let sourceToProxy: [Double] // six affine coefficients; source-oriented pixel centers
  public let bakedBaseEV: Float
  public let candidateNativeEV: [Float]
  public let approximationVersion: String
  public let preparationCold: Bool
  public let preparationNanoseconds: UInt64
  public let bakedStages: [String]
  public let unbakedStages: [String]
  public let tiles: [DevelopmentThumbnailTileDescriptor]
  public let presentationMode: DevelopmentThumbnailPresentationMode
  public let presentationVersion: String?
  public let photoFilterResourceVersion: String?
  public let proxyContentRect:CGRect?
  init(registration:DevelopmentThumbnailRegistration,actualRequest:DevelopmentPreviewRequest,sourceBinding:DevelopmentLocalEditSourceBinding,
       expectedRecipeFingerprint:String,presentedRecipeFingerprint:String,kind:DevelopmentThumbnailKind,target:DevelopmentThumbnailTargetV1,
       contractVersion:Int,pipelineVersion:String,proxyInputFingerprint:String,proxyWidth:Int,proxyHeight:Int,proxyEncoding:String,
       sourceToProxy:[Double],bakedBaseEV:Float,candidateNativeEV:[Float],approximationVersion:String,preparationCold:Bool,
       preparationNanoseconds:UInt64,bakedStages:[String],unbakedStages:[String],tiles:[DevelopmentThumbnailTileDescriptor],
       presentationMode:DevelopmentThumbnailPresentationMode = .texture,presentationVersion:String? = nil,photoFilterResourceVersion:String? = nil,
       proxyContentRect:CGRect? = nil) {
    self.registration=registration;self.actualRequest=actualRequest;self.sourceBinding=sourceBinding
    self.expectedRecipeFingerprint=expectedRecipeFingerprint;self.presentedRecipeFingerprint=presentedRecipeFingerprint
    self.kind=kind;self.target=target;self.contractVersion=contractVersion;self.pipelineVersion=pipelineVersion
    self.proxyInputFingerprint=proxyInputFingerprint;self.proxyWidth=proxyWidth;self.proxyHeight=proxyHeight;self.proxyEncoding=proxyEncoding
    self.sourceToProxy=sourceToProxy;self.bakedBaseEV=bakedBaseEV;self.candidateNativeEV=candidateNativeEV
    self.approximationVersion=approximationVersion;self.preparationCold=preparationCold;self.preparationNanoseconds=preparationNanoseconds
    self.bakedStages=bakedStages;self.unbakedStages=unbakedStages;self.tiles=tiles;self.presentationMode=presentationMode
    self.presentationVersion=presentationVersion;self.photoFilterResourceVersion=photoFilterResourceVersion
    self.proxyContentRect=proxyContentRect
  }
}
/// Service-held ready resource. There is no image/texture read access before adoption.
public struct DevelopmentThumbnailReadyLease: Sendable {
  public let setID: UUID
  public let descriptor: DevelopmentThumbnailSetDescriptor
  let ownershipToken: UUID
  init(setID: UUID, descriptor: DevelopmentThumbnailSetDescriptor, ownershipToken: UUID) {
    self.setID=setID;self.descriptor=descriptor;self.ownershipToken=ownershipToken
  }
}
/// Internal implementation records a GPU read fence before calling encode; no texture may escape it.
protocol ThumbnailTextureReadOwner: AnyObject, Sendable {
  func encodeRead(index: Int, commandBuffer: MTLCommandBuffer, encode: (MTLTexture) -> Void) throws
}
/// Read-only display ownership. No NSImage/PNG wrapping or uncharged upload is permitted.
public final class DevelopmentThumbnailDisplayLease: @unchecked Sendable {
  public let setID: UUID
  public let descriptor: DevelopmentThumbnailSetDescriptor
  let ownershipToken: UUID
  private let reader: any ThumbnailTextureReadOwner
  init(setID: UUID, descriptor: DevelopmentThumbnailSetDescriptor, ownershipToken: UUID, reader: any ThumbnailTextureReadOwner) {
    self.setID=setID;self.descriptor=descriptor;self.ownershipToken=ownershipToken;self.reader=reader
  }
  /// Caller must submit this command buffer after encoding. The display owner holds every read
  /// through its actual completion. Texture is valid only within encode and may not be retained.
  public func encodeRead(tile index: Int, commandBuffer: MTLCommandBuffer, _ encode: (MTLTexture) -> Void) throws {
    try reader.encodeRead(index:index,commandBuffer:commandBuffer,encode:encode)
  }
}
public struct DevelopmentThumbnailStatistics: Equatable, Sendable {
  public internal(set) var pending=0,active=0,readySets=0,displaySets=0
  public internal(set) var cpuBytes=0,gpuBytes=0,unionBytes=0,reservedBytes=0,inFlightBytes=0,retiredBytes=0
  public internal(set) var peakUnionBytes=0
  public internal(set) var completed:UInt64=0,cancelled:UInt64=0
  public internal(set) var maximumStepNanoseconds:UInt64=0
  public internal(set) var managedBackingBytes=0,managedBackingCount=0,retiredManagedBackingBytes=0
  public init() {}
}
public enum DevelopmentThumbnailBudgetV1 {
  public static let summaryBytes=8*1024*1024
  public static let filterBytes=5*1024*1024
  public static let proxyBytes=1024*1024
  public static let totalBytes=14*1024*1024
  public static let proxyMaximumPixel=256
}
