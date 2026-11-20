import XCTest
import AppKit
import CoreImage
import CryptoKit
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentThumbnailPresentationTests:XCTestCase {
  private func request(_ mode:DevelopmentThumbnailPresentationMode = .texture)throws->DevelopmentThumbnailRequest {
    let recipe=DevelopmentRecipe(adjustmentsV3:.init())
    return .init(registration:.init(visibleGeneration:1),preview:.init(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:.settled),
      expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128,presentationMode:mode)
  }
  private func descriptor(_ tile:DevelopmentThumbnailTileDescriptor)throws->DevelopmentThumbnailSetDescriptor {
    let r=try request(.managedImage)
    return .init(registration:r.registration,actualRequest:r.preview,
      sourceBinding:.init(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:19,orientedHeight:7),
      expectedRecipeFingerprint:r.expectedRecipeFingerprint,presentedRecipeFingerprint:r.presentedRecipeFingerprint,kind:r.kind,target:r.target,
      contractVersion:1,pipelineVersion:"actual-tiny-transport",proxyInputFingerprint:String(repeating:"b",count:64),proxyWidth:19,proxyHeight:7,
      proxyEncoding:"tiny",sourceToProxy:[1,0,0,1,0,0],bakedBaseEV:0,candidateNativeEV:[0],approximationVersion:"test-only",
      preparationCold:false,preparationNanoseconds:0,bakedStages:[],unbakedStages:[],tiles:[tile],presentationMode:.managedImage,
      presentationVersion:ThumbnailImageBacking.version)
  }
  private func surface(_ ledger:ThumbnailLedger,filled:Bool=true,finished:Bool=true)throws->(ThumbnailSurface,DevelopmentThumbnailTileDescriptor) {
    guard let device=MTLCreateSystemDefaultDevice()else{throw XCTSkip("Actual Metal device unavailable")}
    let surface=try ThumbnailSurface(width:19,height:7,float:false,kind:.summary,ledger:ledger,device:device)
    if filled {
      let bytes=(0..<(19*7)).flatMap{i->[UInt8] in
        let a=i%4==0 ? 0:(i%4==1 ? 128:255)
        return [UInt8(((i*7)%256)*a/255),UInt8(((i*11)%256)*a/255),UInt8(((i*19)%256)*a/255),UInt8(a)]
      }
      let input=CIImage(bitmapData:Data(bytes),bytesPerRow:19*4,size:.init(width:19,height:7),format:.RGBA8,colorSpace:PhotoRenderer.sRGB)
      let context=CIContext(mtlDevice:device,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
      defer{context.clearCaches()};try surface.fill(input,context:context)
    }
    if finished{surface.finishProducer()}
    let tile=DevelopmentThumbnailTileDescriptor(index:0,summaryAmount:0,filter:nil,actualRecipe:DevelopmentRecipe(adjustmentsV3:.init()),
      actualRecipeFingerprint:try EditingFingerprint.of(DevelopmentRecipe(adjustmentsV3:.init())),width:19,height:7,allocation:surface.allocation,
      storageFormat:"rgba8Unorm/top-row-first",destinationColorSpace:"sRGB",destinationICCProfileSHA256:SHA256.hash(data:PhotoRenderer.sRGB.copyICCData()! as Data).map{String(format:"%02x",$0)}.joined(),alphaPolicy:"premultiplied")
    return(surface,tile)
  }
  private func owner(_ ledger:ThumbnailLedger)throws->ThumbnailSetOwner {
    let(s,t)=try surface(ledger);defer{s.retire()}
    let b=try ThumbnailImageBacking(copying:s,tile:t,ledger:ledger,kind:.summary),tile=b.tileDescriptor(from:t)
    return ThumbnailSetOwner(descriptor:try descriptor(tile),surfaces:[],managedBackings:[b],gate:ThumbnailDeliveryGate())
  }
  func testModeDefaultsAndManagedRequestRemainTyped()throws {
    XCTAssertEqual(try request().presentationMode,.texture)
    let r=try request(.managedImage);try r.validate();XCTAssertEqual(r.presentationMode,.managedImage)
  }
  func testManagedLedgerPhaseAndRepeatedReleaseStayActual()throws {
    let ledger=ThumbnailLedger(),ticket=try ledger.reserve(4096,kind:.summary)
    try ticket.adjust(bytes:4096,cpu:4096,gpu:0);ticket.markManaged();ticket.phase(.retired)
    XCTAssertEqual(ledger.snapshot().managedBackingBytes,4096);XCTAssertEqual(ledger.snapshot().retiredManagedBackingBytes,4096)
    XCTAssertEqual(ledger.snapshot().gpuBytes,0);ticket.release();ticket.release()
    XCTAssertEqual(ledger.snapshot().unionBytes,0);XCTAssertEqual(ledger.snapshot().managedBackingCount,0)
  }
  func testActualJoinedCopyMatchesEveryRowAndPaddingICCAlphaExactly()throws {
    let ledger=ThumbnailLedger()
    try autoreleasepool {
      let(s,t)=try surface(ledger);defer{s.retire()}
      let b=try ThumbnailImageBacking(copying:s,tile:t,ledger:ledger,kind:.summary);defer{b.detach()}
      let cg=try b.getImage(),bytes=cg.dataProvider!.data! as Data,row=cg.bytesPerRow
      XCTAssertEqual(cg.width,19);XCTAssertEqual(cg.height,7);XCTAssertEqual(cg.bitsPerComponent,8)
      XCTAssertEqual(cg.alphaInfo,.premultipliedLast);XCTAssertEqual(cg.bitmapInfo.intersection(.byteOrderMask),.byteOrder32Big)
      XCTAssertEqual(b.descriptor.allocation.residentGPUBytes,0);XCTAssertGreaterThanOrEqual(b.descriptor.allocation.unionBytes,row*7)
      XCTAssertEqual(SHA256.hash(data:cg.colorSpace!.copyICCData()! as Data).map{String(format:"%02x",$0)}.joined(),t.destinationICCProfileSHA256)
      try s.withRGBA8Pixels { p,stride in
        for y in 0..<7 {for x in 0..<(19*4){XCTAssertEqual(bytes[y*row+x],p.load(fromByteOffset:y*stride+x,as:UInt8.self))}}
      }
      for y in 0..<7 {for x in (19*4)..<row {XCTAssertEqual(bytes[y*row+x],0)}}
    }
    XCTAssertEqual(ledger.snapshot().unionBytes,0)
  }
  func testReadBeforeProducerCompletionRejectsAndFreesFailedCopy()throws {
    let ledger=ThumbnailLedger(),(s,t)=try surface(ledger,filled:false,finished:false)
    let original=ledger.snapshot().unionBytes
    XCTAssertThrowsError(try ThumbnailImageBacking(copying:s,tile:t,ledger:ledger,kind:.summary)) {
      XCTAssertEqual($0 as? DevelopmentThumbnailError,.invalidLease)
    }
    XCTAssertEqual(ledger.snapshot().unionBytes,original);XCTAssertEqual(ledger.snapshot().managedBackingBytes,0)
    s.finishProducer();s.retire();XCTAssertEqual(ledger.snapshot().unionBytes,0)
  }
  func testCPUCapacityFailureDoesNotExposeImageOrRetryPipeline()throws {
    let ledger=ThumbnailLedger(),(s,t)=try surface(ledger);defer{s.retire()}
    let held=try ledger.reserve(DevelopmentThumbnailBudgetV1.summaryBytes-ledger.snapshot().unionBytes,kind:.summary)
    defer{held.release()}
    XCTAssertThrowsError(try ThumbnailImageBacking(copying:s,tile:t,ledger:ledger,kind:.summary)) {
      XCTAssertEqual($0 as? DevelopmentThumbnailError,.budgetUnavailable)
    }
    XCTAssertEqual(ledger.snapshot().managedBackingBytes,0)
  }
  func testAdoptionModesRevocationAndRetainedReleasedLeaseClearPrivateViews()async throws {
    let ledger=ThumbnailLedger(),o=try autoreleasepool{try owner(ledger)}
    XCTAssertThrowsError(try o.adopt())
    let presentation=try o.adoptPresentation();XCTAssertEqual(presentation.tiles.count,1)
    XCTAssertThrowsError(try o.adoptPresentation())
    try autoreleasepool{_ = try presentation.cgImage(tile:0)}
    o.revokeReads();XCTAssertThrowsError(try presentation.cgImage(tile:0))
    await o.retireAndJoin()
    // `presentation` still retains its reader/descriptor, but no image/provider/storage.
    XCTAssertEqual(ledger.snapshot().unionBytes,0);withExtendedLifetime(presentation){}
  }
  func testExternalCGAndNSImageAliasesStayChargedAcrossCloseUntilLastRelease()async throws {
    let ledger=ThumbnailLedger(),o=try autoreleasepool{try owner(ledger)},presentation=try o.adoptPresentation()
    var cg:CGImage?=try presentation.cgImage(tile:0),ns:NSImage?
    autoreleasepool{ns=NSImage(cgImage:cg!,size:.init(width:19,height:7))}
    let allocated=ledger.snapshot().managedBackingBytes;XCTAssertGreaterThan(allocated,0)
    o.revokeReads();await o.retireAndJoin() // Does not wait for the two external aliases.
    XCTAssertEqual(ledger.snapshot().retiredManagedBackingBytes,allocated)
    XCTAssertEqual(cg?.width,19);XCTAssertEqual(ns?.size.width,19)
    cg=nil;XCTAssertEqual(ledger.snapshot().managedBackingBytes,allocated)
    ns=nil;XCTAssertEqual(ledger.snapshot().managedBackingBytes,0)
    withExtendedLifetime(presentation){}
  }
}
