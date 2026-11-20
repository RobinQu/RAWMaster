import Foundation
import CoreGraphics
import CryptoKit
import Darwin

public struct DevelopmentThumbnailPresentationTileDescriptor: Sendable {
  public let index:Int
  public let width:Int
  public let height:Int
  public let allocation:DevelopmentThumbnailAllocation
  public let storageFormat:String
  public let destinationICCProfileSHA256:String
}
protocol ThumbnailPresentationReadOwner: AnyObject,Sendable {
  func cgImage(index:Int)throws->CGImage
}
public final class DevelopmentThumbnailPresentationLease: @unchecked Sendable {
  public let setID:UUID
  public let descriptor:DevelopmentThumbnailSetDescriptor
  public let tiles:[DevelopmentThumbnailPresentationTileDescriptor]
  let ownershipToken:UUID
  private let reader:any ThumbnailPresentationReadOwner
  init(setID:UUID,descriptor:DevelopmentThumbnailSetDescriptor,tiles:[DevelopmentThumbnailPresentationTileDescriptor],ownershipToken:UUID,reader:any ThumbnailPresentationReadOwner) {
    self.setID=setID;self.descriptor=descriptor;self.tiles=tiles;self.ownershipToken=ownershipToken;self.reader=reader
  }
  /// Same immutable image, not a copy. Returned aliases keep the provider/ticket across close.
  public func cgImage(tile index:Int)throws->CGImage {try reader.cgImage(index:index)}
}

/// Provider owns this storage; storage deliberately never owns a provider or CGImage.
private final class ThumbnailProviderStorage {
  let pointer:UnsafeMutableRawPointer,bytes:Int,ticket:ThumbnailTicket
  init(reserved:Int,ledger:ThumbnailLedger,kind:ThumbnailLedger.Kind)throws {
    ticket=try ledger.reserve(reserved,kind:kind)
    guard let p=malloc(reserved)else{ticket.release();throw DevelopmentThumbnailError.budgetUnavailable}
    let actual=malloc_size(p)
    do {
      try ticket.adjust(bytes:actual,cpu:actual,gpu:0)
      guard actual<=reserved else{throw DevelopmentThumbnailError.invalidEncoding}
    }catch{free(p);ticket.release();throw error}
    pointer=p;bytes=actual;memset(p,0,actual);ticket.markManaged()
  }
  deinit {free(pointer);ticket.release()}
}

/// Only the CGDataProvider holds the physical pointer owner after creation. Detaching clears
/// this owner's image reference; outside CG/NSImage aliases retain storage and its retired bill.
final class ThumbnailImageBacking: @unchecked Sendable {
  static let version="thumbnail-managed-rgba8-provider-v1"
  static let format="RGBA8/premultipliedLast/byteOrder32Big/top-row-first"
  let descriptor:DevelopmentThumbnailPresentationTileDescriptor
  private let ticket:ThumbnailTicket
  private let lock=NSLock()
  private var image:CGImage?
  init(copying surface:ThumbnailSurface,tile:DevelopmentThumbnailTileDescriptor,ledger:ThumbnailLedger,kind:ThumbnailLedger.Kind)throws {
    guard !surface.float,surface.width==tile.width,surface.height==tile.height,
      let icc=PhotoRenderer.sRGB.copyICCData() as Data?,
      SHA256.hash(data:icc).map({String(format:"%02x",$0)}).joined()==tile.destinationICCProfileSHA256 else{throw DevelopmentThumbnailError.invalidEncoding}
    let row=((surface.width*4+63)/64)*64
    let (length,overflow)=row.multipliedReportingOverflow(by:surface.height)
    guard !overflow,length>0 else{throw DevelopmentThumbnailError.invalidEncoding}
    let storage=try ThumbnailProviderStorage(reserved:malloc_good_size(length),ledger:ledger,kind:kind)
    try surface.withRGBA8Pixels{pointer,stride in
      guard stride>=surface.width*4 else{throw DevelopmentThumbnailError.invalidEncoding}
      for y in 0..<surface.height {memcpy(storage.pointer.advanced(by:y*row),pointer.advanced(by:y*stride),surface.width*4)}
    }
    let retained=Unmanaged.passRetained(storage)
    guard let provider=CGDataProvider(dataInfo:retained.toOpaque(),data:UnsafeRawPointer(storage.pointer),size:length,releaseData:{info,_,_ in
      if let info {Unmanaged<ThumbnailProviderStorage>.fromOpaque(info).release()}
    })else{retained.release();throw DevelopmentThumbnailError.invalidEncoding}
    let info=CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)
    guard let cg=CGImage(width:surface.width,height:surface.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:row,
      space:PhotoRenderer.sRGB,bitmapInfo:info,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)else{throw DevelopmentThumbnailError.invalidEncoding}
    ticket=storage.ticket;image=cg
    descriptor = .init(index:tile.index,width:surface.width,height:surface.height,
      allocation:.init(allocationID:ticket.id,residentCPUBytes:storage.bytes,residentGPUBytes:0,unionBytes:storage.bytes,bytesPerRow:row),
      storageFormat:Self.format,destinationICCProfileSHA256:tile.destinationICCProfileSHA256)
  }
  func getImage()throws->CGImage {lock.lock();defer{lock.unlock()};guard let image else{throw DevelopmentThumbnailError.invalidLease};return image}
  func phase(_ value:ThumbnailLedger.Phase){ticket.phase(value)}
  func detach(){ticket.phase(.retired);lock.lock();image=nil;lock.unlock()}
  func tileDescriptor(from tile:DevelopmentThumbnailTileDescriptor)->DevelopmentThumbnailTileDescriptor {
    .init(index:tile.index,summaryAmount:tile.summaryAmount,filter:tile.filter,actualRecipe:tile.actualRecipe,
      actualRecipeFingerprint:tile.actualRecipeFingerprint,width:descriptor.width,height:descriptor.height,allocation:descriptor.allocation,
      storageFormat:descriptor.storageFormat,destinationColorSpace:tile.destinationColorSpace,
      destinationICCProfileSHA256:descriptor.destinationICCProfileSHA256,alphaPolicy:tile.alphaPolicy)
  }
  deinit{detach()}
}
