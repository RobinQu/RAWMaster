import XCTest
import Foundation
import AppKit
import ImageIO
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

private enum MetadataDiagnosticError:Error { case failed(String) }
private func metadataRequire(_ condition:Bool,_ message:String)throws{if !condition{throw MetadataDiagnosticError.failed(message)}}
private func metadataSHA(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
private func metadataStamp(_ url:URL)throws->[String:Any]{let s=try PreviewFileStamp.read(url);return["device":s.device,"inode":s.inode,"size":s.size,"mtimeSeconds":s.seconds,"mtimeNanoseconds":s.nanoseconds,"ctimeSeconds":s.changedSeconds,"ctimeNanoseconds":s.changedNanoseconds]}
private func metadataStat(_ path:String,fd:Int32?=nil)throws->[String:Any]{
  var s=stat();let result:Int32
  if let fd{result=Darwin.fstat(fd,&s)}else{result=Darwin.fstatat(AT_FDCWD,path,&s,0)}
  guard result==0 else{throw MetadataDiagnosticError.failed("stat errno \(errno)")}
  return["device":s.st_dev,"inode":s.st_ino,"size":s.st_size,"mode":s.st_mode,"flags":s.st_flags,"nlink":s.st_nlink,"mtimeSeconds":s.st_mtimespec.tv_sec,"mtimeNanoseconds":s.st_mtimespec.tv_nsec,"ctimeSeconds":s.st_ctimespec.tv_sec,"ctimeNanoseconds":s.st_ctimespec.tv_nsec,"atimeSeconds":s.st_atimespec.tv_sec,"atimeNanoseconds":s.st_atimespec.tv_nsec]
}
private func metadataXattrs(_ path:String)throws->[[String:Any]]{
  let count=Darwin.listxattr(path,nil,0,0);try metadataRequire(count>=0 && count<=65_536,"xattr name-list errno/size \(errno)/\(count)")
  var bytes=[UInt8](repeating:0,count:count)
  let read=bytes.withUnsafeMutableBytes{Darwin.listxattr(path,$0.baseAddress?.assumingMemoryBound(to:CChar.self),count,0)}
  try metadataRequire(read==count,"xattr list changed/error; no retry")
  let names=bytes.split(separator:0).map{String(decoding:$0,as:UTF8.self)}.sorted();try metadataRequire(names.count<=64,"xattr count limit")
  return try names.map{name in
    let size=Darwin.getxattr(path,name,nil,0,0,0);try metadataRequire(size>=0 && size<=65_536,"xattr value errno/size \(name) \(errno)/\(size)")
    var data=Data(count:size);let read=data.withUnsafeMutableBytes{Darwin.getxattr(path,name,$0.baseAddress,size,0,0)}
    try metadataRequire(read==size,"xattr value changed/error; no retry")
    return["name":name,"bytes":size,"SHA256":metadataSHA(data)]
  }
}
private func metadataStats(_ s:PreviewStatistics)->[String:Any]{["invalidations":s.invalidations,"captures":s.sourceCaptures,"fullHashPasses":s.sourceFullHashPasses,"hashBytes":s.sourceHashBytes,"statChecks":s.sourceStatChecks,"renders":s.completedRenders,"activeNative":s.activeNativeRenders,"nativeMax":s.maximumObservedNativeRenders,"pending":s.pendingRequests,"fills":s.rawBaseFills,"hits":s.rawBaseHits,"ownedUnion":s.rawBaseResidentBytes+s.rawBaseReservedBytes+s.rawBaseBuildingBytes+s.rawBaseRetiredBytes,"pinned":s.rawBasePinnedBytes,"snapshotDiskBytes":s.sourceSnapshotDiskBytes]}
private final class MetadataVnodeObserver:@unchecked Sendable{
  private let lock=NSLock(),queue=DispatchQueue(label:"020.metadata-vnode"),cancelled=DispatchGroup()
  private let url:URL,fd:Int32,service:DevelopmentPreviewService
  private var source:DispatchSourceFileSystemObject?,phase="watcher-created",events:[[String:Any]]=[],tasks:[Task<Void,Never>]=[],error:String?
  init(_ url:URL,service:DevelopmentPreviewService)throws{
    self.url=url;self.service=service;fd=Darwin.open(url.path,O_EVTONLY)
    guard fd>=0 else{throw MetadataDiagnosticError.failed("O_EVTONLY errno \(errno)")}
    let s=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.delete,.rename,.attrib,.revoke],queue:queue);source=s;cancelled.enter()
    let ownedFD=fd,group=cancelled;s.setCancelHandler{Darwin.close(ownedFD);group.leave()}
    s.setEventHandler{[weak self]in self?.event()};s.resume()
  }
  func label(_ value:String){lock.lock();phase=value;lock.unlock()}
  private func snapshot()throws->[String:Any]{["previewIdentity":try metadataStamp(url),"pathStat":try metadataStat(url.path),"watchFDStat":try metadataStat(url.path,fd:fd),"xattrs":try metadataXattrs(url.path)]}
  func observation()throws->[String:Any]{try snapshot()}
  private func event(){
    let at=DispatchTime.now().uptimeNanoseconds,mask=source?.data.rawValue ?? 0
    lock.lock();let p=phase,index=events.count;guard index<256 else{error=error ?? "vnode event overflow";lock.unlock();return};events.append(["at":at,"phase":p,"rawMask":mask]);lock.unlock()
    do{let observation=try snapshot();lock.lock();events[index]["metadata"]=observation;lock.unlock()}catch{lock.lock();self.error=self.error ?? String(describing:error);events[index]["metadataError"]=String(describing:error);lock.unlock()}
    let service=self.service
    let task=Task{let s=await service.statistics();self.attachStatistics(s,index:index)}
    tasks.append(task) // Only serial observer queue mutates bounded Void-task ownership.
  }
  private func attachStatistics(_ s:PreviewStatistics,index:Int){lock.lock();defer{lock.unlock()};events[index]["publicStatistics"]=metadataStats(s);events[index]["statisticsObservedAt"]=DispatchTime.now().uptimeNanoseconds}
  var failure:String?{lock.lock();defer{lock.unlock()};return error}
  private func report()->([String:Any],String?){lock.lock();defer{lock.unlock()};return(["events":events,"eventCount":events.count,"maskScope":"independent O_EVTONLY observer, NOT internalService handler log","maxEvents":256,"statisticsTimeScope":"actual public actor observation after event, separately timestamped, not atomic with fstat"],error)}
  func finish()async->([String:Any],String?){
    let pending:[Task<Void,Never>]=queue.sync{source?.cancel();source=nil;return tasks}
    await withCheckedContinuation{continuation in cancelled.notify(queue:queue){continuation.resume()}}
    for task in pending{await task.value};return report()
  }
}
@MainActor final class SourceMetadataDiagnosticTests:XCTestCase{
  func testOptInOneMetadataOnlyVnodeSequence()async throws{
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_METADATA_DIAGNOSTIC"]=="1",let repoPath=env["RAWMASTER_METADATA_REPOSITORY"],let outputPath=env["RAWMASTER_METADATA_OUTPUT"],let freezePath=env["RAWMASTER_METADATA_FREEZE"],let freezeSHA=env["RAWMASTER_METADATA_FREEZE_SHA256"]else{throw XCTSkip("Explicit ONE test-only metadata/no-render grant required")}
    #if DEBUG
    throw MetadataDiagnosticError.failed("ordinaryRELEASE required")
    #endif
    let repo=URL(fileURLWithPath:repoPath),out=URL(fileURLWithPath:outputPath),freezeData=try Data(contentsOf:URL(fileURLWithPath:freezePath))
    try metadataRequire(metadataSHA(freezeData)==freezeSHA,"exact freezeSHA")
    let frozen=try JSONSerialization.jsonObject(with:freezeData)as![String:Any]
    try metadataRequire(frozen["rootActualOneRunGrant"]as?Bool==true && frozen["outputPath"]as?String==out.path,"grant/output")
    guard let binary=Bundle(for:SourceMetadataDiagnosticTests.self).executableURL else{throw MetadataDiagnosticError.failed("test binary")}
    try metadataRequire(try RenderFiles.hash(binary)==frozen["binarySHA256"]as?String,"binary freeze")
    for(name,expected)in frozen["producerSHA256"]as![String:String]{try metadataRequire(try RenderFiles.hash(repo.appendingPathComponent(name))==expected,"producer "+name)}
    try metadataRequire(!FileManager.default.fileExists(atPath:out.path),"new output")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false)
    let safety=NativeTransportSafety();safety.start();let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824))
    var observer:MetadataVnodeObserver?,rows:[[String:Any]]=[],failure:String?,monitor:[String:Any]=[:],preSHA:String?,postSHA:String?,copyPre:String?,copyPost:String?,observedInvalidation=false
    var source:EditingSourceSnapshot?,copy:EditingSourceSnapshot?
    func check(_ label:String)throws{safety.label(label);_=safety.observe();try Host4TrialContract.check(safety)}
    func record(_ label:String,_ extra:[String:Any]=[:])async throws{
      try check(label);let s=await service.statistics();try metadataRequire(s.completedRenders==0 && s.activeNativeRenders==0 && s.maximumObservedNativeRenders==0 && s.rawBaseFills==0,"no render/materialization")
      var r:[String:Any]=["label":label,"at":DispatchTime.now().uptimeNanoseconds,"publicStatistics":metadataStats(s)]
      if let observer{if let error=observer.failure{throw MetadataDiagnosticError.failed(error)};r["metadata"]=try observer.observation()};for(k,v)in extra{r[k]=v};rows.append(r);try metadataRequire(rows.count<=64,"phase overflow")
      if s.invalidations>0{observedInvalidation=true}
    }
    func window(_ label:String)async throws{try await Task.sleep(nanoseconds:100_000_000);try await record(label+"/after-fixed100ms")}
    func properties(_ url:URL)throws->[String:Any]{try autoreleasepool{
      guard let image=CGImageSourceCreateWithURL(url as CFURL,nil),let p=CGImageSourceCopyPropertiesAtIndex(image,0,nil)as?[CFString:Any]else{throw MetadataDiagnosticError.failed("ImageIO properties")}
      return["naturalEXIF":(p[kCGImagePropertyOrientation]as?NSNumber)?.intValue as Any? ?? NSNull(),"imageCount":CGImageSourceGetCount(image)]
    }}
    do{
      let original=EditingSourceSnapshot(projectID:"020-final-FIT",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"frozen-020-reference",sourceLocation:repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"));source=original
      try check("COPY-preflight/original-before");let originalBefore=try metadataStat(original.sourceLocation.path);preSHA=try RenderFiles.hash(original.sourceLocation);try metadataRequire(preSHA==original.contentSHA256,"original prehash")
      let url=out.appendingPathComponent("DSC05994-authorized-copy.ARW");try FileManager.default.copyItem(at:original.sourceLocation,to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
      var c=original;c.sourceLocation=url;copy=c;observer=try MetadataVnodeObserver(url,service:service);observer?.label("COPY-preflight/verify")
      try await record("COPY-preflight/before-verify",["originalBeforeStat":originalBefore,"originalPreSHA256":preSHA!]);try RenderFiles.verify(c);copyPre=try RenderFiles.hash(url);try metadataRequire(copyPre==original.contentSHA256,"copy prehash");try await record("COPY-preflight/after-verify");try await window("COPY-preflight")
      observer?.label("SUT-open-A");try await record("SUT-open-A/before");let first=try await service.open(source:.raw(c));try await record("SUT-open-A/after",["lease":first.id.rawValue.uuidString,"generation":first.sourceGeneration,"decoder":first.decoderVersion]);try await window("SUT-open-A")
      observer?.label("ImageIO-properties-1");try await record("ImageIO-properties-1/before");let props1=try properties(url);try await record("ImageIO-properties-1/after",props1);try await window("ImageIO-properties-1")
      observer?.label("hash-1");try await record("hash-1/before");let hash1=try RenderFiles.hash(url);try await record("hash-1/after",["actualSHA256":hash1]);try metadataRequire(hash1==original.contentSHA256,"hash1");try await window("hash-1")
      observer?.label("SUT-shared-open");try await record("SUT-shared-open/before");let second=try await service.open(source:.raw(c));try await record("SUT-shared-open/after",["lease":second.id.rawValue.uuidString,"generation":second.sourceGeneration,"decoder":second.decoderVersion]);try await window("SUT-shared-open")
      observer?.label("ImageIO-properties-2");try await record("ImageIO-properties-2/before");let props2=try properties(url);try await record("ImageIO-properties-2/after",props2);try await window("ImageIO-properties-2")
      observer?.label("hash-2");try await record("hash-2/before");copyPost=try RenderFiles.hash(url);try await record("hash-2/after",["actualSHA256":copyPost!]);try metadataRequire(copyPost==original.contentSHA256,"copy posthash");try await window("hash-2")
      observer?.label("final-fixed500ms-window");try await Task.sleep(nanoseconds:500_000_000);try await record("final-fixed500ms-window/after")
      try check("original-posthash");postSHA=try RenderFiles.hash(original.sourceLocation);try metadataRequire(postSHA==preSHA,"original posthash");try await record("original-posthash/after",["originalPostSHA256":postSHA!,"originalPostStat":try metadataStat(original.sourceLocation.path)])
    }catch{failure=String(describing:error)}
    await service.closeAll();let closed=await service.statistics()
    if let observer{let(value,error)=await observer.finish();monitor=value;if let error{failure=failure ?? error}}
    safety.label("diagnostic-close-joined");_=safety.observe();safety.stop()
    if let abort=safety.abortReason{failure=failure ?? abort};if safety.highWater>Host4TrialContract.host4{failure=failure ?? "host4GiBExceeded"}
    let noNative=closed.completedRenders==0 && closed.activeNativeRenders==0 && closed.rawBaseFills==0,drained=closed.sourceSnapshotDiskBytes==0 && closed.rawBaseResidentBytes+closed.rawBaseRetiredBytes+closed.rawBaseReservedBytes+closed.rawBaseBuildingBytes+closed.rawBasePinnedBytes==0
    let complete=failure==nil && preSHA==postSHA && copyPre==copyPost && preSHA != nil && noNative && drained
    var receipt:[String:Any]=["diagnosticComplete":complete,"failure":failure as Any? ?? NSNull(),"reproduction":observedInvalidation ? "lease invalidation observed, cause requires stage/event review":"unreproduced under fixed diagnostic windows","closedStatistics":metadataStats(closed),"noNativeMaterialization":noNative,"drained":drained,"operationalAbort":safety.abortReason as Any? ?? NSNull(),"target3Pass":safety.abortReason==nil && safety.highWater<=Host4TrialContract.target3,"host4Pass":safety.abortReason==nil && safety.highWater<=Host4TrialContract.host4,"actualOriginalPreSHA256":preSHA as Any? ?? NSNull(),"actualOriginalPostSHA256":postSHA as Any? ?? NSNull(),"actualCopyPreSHA256":copyPre as Any? ?? NSNull(),"actualCopyPostSHA256":copyPost as Any? ?? NSNull(),"producerFreezeSHA256":freezeSHA,"timingScope":"fixed perstep100ms/final500ms diagnosis only, NOT performance; event phase is observation label not causal proof","actualCapturedSHA256":NSNull(),"sourceSnapshot":source.map{$0.sourceLocation.path} as Any? ?? NSNull(),"copySnapshot":copy.map{$0.sourceLocation.path} as Any? ?? NSNull(),"after":"STOP no automatic fullDual retry/production change" ]
    if safety.abortReason != nil || safety.highWater>Host4TrialContract.host4{receipt["minimalIncompleteReceipt"]=true;receipt["sampledHighWaterBytes"]=safety.highWater}else{receipt["rows"]=rows;receipt["vnodeObserver"]=monitor;receipt["periodic"]=safety.report()}
    let file=out.appendingPathComponent("receipt.json");try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:file);try h.synchronize();try h.close();let fd=Darwin.open(out.path,O_RDONLY);guard fd>=0 else{throw MetadataDiagnosticError.failed("outputdir")};let status=Darwin.fsync(fd);Darwin.close(fd);try metadataRequire(status==0,"dirfsync")
    XCTAssertTrue(complete)
  }
}
