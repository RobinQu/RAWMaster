import XCTest
import AppKit
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class SourceWatcherAttributeTests:XCTestCase{
  private func fixture()throws->(URL,EditingSourceSnapshot){
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("watcher-attribute-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let url=root.appendingPathComponent("source.png"),b=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32)!
    for i in 0..<(16*12){b.bitmapData![i*4]=UInt8(i%256);b.bitmapData![i*4+1]=80;b.bitmapData![i*4+2]=120;b.bitmapData![i*4+3]=255}
    let d=b.representation(using:.png,properties:[:])!;try d.write(to:url)
    return(root,.init(projectID:"watcher-test",assetID:"a",contentSHA256:SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined(),byteCount:Int64(d.count),admissionFingerprint:"admitted",sourceLocation:url))
  }
  private func request(_ info:PreviewSessionInfo,_ revision:UInt64=1)->DevelopmentPreviewRequest{.init(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:.init(),role:.primary,revision:revision,recipe:.init(),quality:.settled)}
  private func event(_ s:DevelopmentPreviewService,_ lease:PreviewSessionInfo,_ source:EditingSourceSnapshot,_ stamp:PreviewFileStamp,_ bits:UInt)async{await s.receiveSourceWatcherEvent(lease.id,generation:lease.sourceGeneration,url:source.sourceLocation,stamp:stamp,rawBits:bits)}
  private func invalid(_ operation:()async throws->Void)async{do{try await operation();XCTFail("Invalidated registration delivered")}catch DevelopmentPreviewError.sourceInvalidated{}catch{XCTFail("\(error)")}}
  func testPureAttributeSameIdentityPreservesSharedLeasesAndBitmap()async throws{
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let s=DevelopmentPreviewService(),a=try await s.open(source:.raw(source)),b=try await s.open(source:.raw(source)),stamp=try PreviewFileStamp.read(source.sourceLocation)
    let frame=try await s.render(request(a));await event(s,a,source,stamp,DispatchSource.FileSystemEvent.attrib.rawValue)
    let x=try await s.render(request(a,2)),y=try await s.render(request(b,2));XCTAssertEqual(x.outputKey,frame.outputKey);XCTAssertEqual(y.outputKey,frame.outputKey)
    let stats=await s.statistics();XCTAssertEqual(stats.invalidations,0);XCTAssertEqual(stats.cacheHits,2);XCTAssertEqual(stats.sourceFullHashPasses,1);await s.closeAll()
  }
  func testPureAttributeRealCTimeChangeAndMissingPathRevokeSharedLeases()async throws{
    for missing in [false,true]{
      let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
      let s=DevelopmentPreviewService(),a=try await s.open(source:.raw(source)),b=try await s.open(source:.raw(source)),stamp=try PreviewFileStamp.read(source.sourceLocation)
      if missing{try FileManager.default.removeItem(at:source.sourceLocation)}else{try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:source.sourceLocation.path);XCTAssertNotEqual(try PreviewFileStamp.read(source.sourceLocation),stamp)}
      await event(s,a,source,stamp,DispatchSource.FileSystemEvent.attrib.rawValue)
      await invalid{_ = try await s.render(self.request(a))};await invalid{_ = try await s.render(self.request(b))};let stats=await s.statistics();XCTAssertEqual(stats.invalidations,2);await s.closeAll()
    }
  }
  func testDangerousMixedUnknownAndEmptyEventsForceRevokeWithSameStamp()async throws{
    let values:[UInt]=[DispatchSource.FileSystemEvent.write.rawValue,DispatchSource.FileSystemEvent.delete.rawValue,DispatchSource.FileSystemEvent.rename.rawValue,DispatchSource.FileSystemEvent.revoke.rawValue,DispatchSource.FileSystemEvent.write.union(.attrib).rawValue,1<<30,0]
    for bits in values{
      let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
      let s=DevelopmentPreviewService(),a=try await s.open(source:.raw(source)),b=try await s.open(source:.raw(source)),stamp=try PreviewFileStamp.read(source.sourceLocation)
      await event(s,a,source,stamp,bits);XCTAssertEqual(try PreviewFileStamp.read(source.sourceLocation),stamp)
      await invalid{_ = try await s.render(self.request(a))};await invalid{_ = try await s.render(self.request(b))};let stats=await s.statistics();XCTAssertEqual(stats.invalidations,2);await s.closeAll()
    }
  }
  func testOldGenerationDangerousCallbackCannotRevokeStrictlyRevalidatedLease()async throws{
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let s=DevelopmentPreviewService(),old=try await s.open(source:.raw(source)),stamp=try PreviewFileStamp.read(source.sourceLocation)
    let fresh=try await s.revalidate(old.id,source:.raw(source));XCTAssertNotEqual(old.sourceGeneration,fresh.sourceGeneration)
    let before=await s.statistics();await event(s,old,source,stamp,DispatchSource.FileSystemEvent.write.union(.attrib).rawValue)
    _ = try await s.render(request(fresh));let after=await s.statistics();XCTAssertEqual(after.invalidations,before.invalidations);await s.closeAll()
  }
  func testClosedLeaseDangerousCallbackCannotRevokeFreshSharedOrNewLease()async throws{
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let s=DevelopmentPreviewService(),old=try await s.open(source:.raw(source)),shared=try await s.open(source:.raw(source)),stamp=try PreviewFileStamp.read(source.sourceLocation)
    await s.close(old.id);let fresh=try await s.open(source:.raw(source));await event(s,old,source,stamp,DispatchSource.FileSystemEvent.write.rawValue)
    _ = try await s.render(request(shared));_ = try await s.render(request(fresh));let stats=await s.statistics();XCTAssertEqual(stats.invalidations,0);await s.closeAll()
  }
  func testMismatchedURLOrCapturedStampCannotRevokeCurrentRegistration()async throws{
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let s=DevelopmentPreviewService(),a=try await s.open(source:.raw(source)),stamp=try PreviewFileStamp.read(source.sourceLocation)
    await s.receiveSourceWatcherEvent(a.id,generation:a.sourceGeneration,url:root.appendingPathComponent("other.png"),stamp:stamp,rawBits:DispatchSource.FileSystemEvent.write.rawValue)
    let wrong=PreviewFileStamp(device:stamp.device,inode:stamp.inode+1,size:stamp.size,seconds:stamp.seconds,nanoseconds:stamp.nanoseconds,changedSeconds:stamp.changedSeconds,changedNanoseconds:stamp.changedNanoseconds)
    await s.receiveSourceWatcherEvent(a.id,generation:a.sourceGeneration,url:source.sourceLocation,stamp:wrong,rawBits:DispatchSource.FileSystemEvent.write.rawValue)
    _ = try await s.render(request(a));let stats=await s.statistics();XCTAssertEqual(stats.invalidations,0);await s.closeAll()
  }
}
