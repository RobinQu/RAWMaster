import Foundation
import Darwin
import Metal
import CoreImage

/// QA022 diagnostics only. No source path, recipe payload, pixel, error text or caller dictionary.
/// Separate file avoids racing the AppKit interaction trace writer. Disabled before allocation elsewhere.
enum PreviewQALifecycleTrace {
  enum Kind:String { case render,histogram,userAnalysis,summaryThumbnail,filterThumbnail,lifecycle }
  enum ThumbnailStep:String { case proxy,scalars,tile }
  enum Phase:String { case admitted,entered,returned,joined,cancelled,frame,closedAll }
  struct Limit {
    private(set) var count=0
    mutating func reserve()->Bool? {
      guard count<4096 else{return nil};count+=1;return count==4096
    }
  }
  /// Pure counter used only under Sink's existing lock. Unit is eligible jobs, not gestures.
  struct IPJobLimit {
    private(set) var count=0
    mutating func reserve()->Int? {
      guard count<5 else{return nil};count+=1;return count
    }
  }
  static func enabled(bundleIdentifier:String?,environment:[String:String])->Bool {
    bundleIdentifier=="io.robinqu.RAWMaster.preview022" && environment["RAWMASTER_QA_NATIVE_POINTWISE_V1"]=="1" &&
      environment["RAWMASTER_INTERACTION_TRACE"]?.hasPrefix("/")==true
  }
  private static let sink:Sink? = {
    let env=ProcessInfo.processInfo.environment
    guard enabled(bundleIdentifier:Bundle.main.bundleIdentifier,environment:env),let path=env["RAWMASTER_INTERACTION_TRACE"]else{return nil}
    return Sink(url:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("research022-worker-phases.jsonl"))
  }()
  static var isEnabled:Bool {sink != nil}
  // Mechanism-only QA: two warmups plus three candidate samples. No recipe/path/pixels.
  enum IPPurpose:String,Sendable { case fitCheck,output }
  struct IPTaskScalars:Sendable {
    var count=0,failures=0
    var startCallNS:UInt64?,waitJoinNS:UInt64?
    var kernelExecutionSeconds:Double?,kernelCompileSeconds:Double?
    var passes:Int?,pixelsProcessed:Int?
  }
  struct IPPacket:Sendable {
    let phaseID:UUID,ordinal:Int
    var successful=false,sourceCold:Bool?,samplerCold:Bool?,certified:Bool?
    var idleContextClearNS:UInt64?,contextCreateNS:UInt64?,contextCreateCount=0
    var graphBuildNS:UInt64?,fitCheckWallNS:UInt64?,materializeWallNS:UInt64?
    var contextClearARCWallNS:UInt64=0,contextClearCount=0,timingOverflow=false
    var fitTask=IPTaskScalars(),outputTask=IPTaskScalars()
    func fields()->[String:Any] {
      var r:[String:Any]=["event":"qa022.ip-phases","kind":"render","phase":"ip-phases","atNS":IPTiming.now(),
        "phaseID":phaseID.uuidString,"ordinal":ordinal,
        "sampleKind":ordinal<=2 ? "warmup":"mechanism-sample","successful":successful,
        "sourceCold":sourceCold as Any? ?? NSNull(),"samplerCold":samplerCold as Any? ?? NSNull(),"certified":certified as Any? ?? NSNull(),
        "idleContextClearNS":idleContextClearNS as Any? ?? NSNull(),"contextCreateNS":contextCreateNS as Any? ?? NSNull(),"contextCreateCount":contextCreateCount,
        "graphBuildNS":graphBuildNS as Any? ?? NSNull(),"fitCheckWallNS":fitCheckWallNS as Any? ?? NSNull(),"materializeWallNS":materializeWallNS as Any? ?? NSNull(),
        "contextClearARCWallNS":contextClearARCWallNS,"contextClearCount":contextClearCount,"timingOverflow":timingOverflow,
        "boundary":"joined synchronous local wall; CI statistics are public API values; not device-wide/presentation timing",
        "privateReleaseState":"UNKNOWN","pixelsProcessedMeaning":"CI kernel-produced pixels, NOT RAW reads"]
      for (prefix,t) in [("fit",fitTask),("output",outputTask)] {
        r[prefix+"TaskCount"]=t.count;r[prefix+"TaskFailures"]=t.failures
        r[prefix+"StartCallNS"]=t.startCallNS as Any? ?? NSNull();r[prefix+"WaitJoinNS"]=t.waitJoinNS as Any? ?? NSNull()
        r[prefix+"KernelExecutionSeconds"]=t.kernelExecutionSeconds as Any? ?? NSNull();r[prefix+"KernelCompileSeconds"]=t.kernelCompileSeconds as Any? ?? NSNull()
        r[prefix+"Passes"]=t.passes as Any? ?? NSNull();r[prefix+"PixelsProcessed"]=t.pixelsProcessed as Any? ?? NSNull()
      }
      return r
    }
  }
  /// Constructed and mutated only by the existing synchronous worker; only Packet crosses join.
  final class IPTiming {
    private var p:IPPacket
    init(id:UUID,ordinal:Int){p = .init(phaseID:id,ordinal:ordinal)}
    static func now()->UInt64{DispatchTime.now().uptimeNanoseconds}
    static func elapsed(_ began:UInt64)->UInt64?{let end=now();return end>=began ? end-began:nil}
    func idleClear(_ began:UInt64){p.idleContextClearNS=Self.elapsed(began)}
    func created(_ began:UInt64){p.contextCreateNS=Self.elapsed(began);p.contextCreateCount+=1}
    func graph(_ began:UInt64){p.graphBuildNS=Self.elapsed(began)}
    func fit(_ began:UInt64){p.fitCheckWallNS=Self.elapsed(began)}
    func output(_ began:UInt64){p.materializeWallNS=Self.elapsed(began)}
    func clear(_ began:UInt64){
      guard let n=Self.elapsed(began)else{p.timingOverflow=true;return}
      let(total,bad)=p.contextClearARCWallNS.addingReportingOverflow(n)
      p.timingOverflow = p.timingOverflow || bad;if !bad{p.contextClearARCWallNS=total};p.contextClearCount+=1
    }
    func route(sourceCold:Bool,samplerCold:Bool,certified:Bool){p.sourceCold=sourceCold;p.samplerCold=samplerCold;p.certified=certified}
    func task(_ purpose:IPPurpose,callBegan:UInt64,waitBegan:UInt64?,info:CIRenderInfo?,successful:Bool){
      var v=purpose == .fitCheck ? p.fitTask:p.outputTask
      v.count+=1;if !successful{v.failures+=1}
      if let waitBegan,waitBegan>=callBegan{v.startCallNS=waitBegan-callBegan;v.waitJoinNS=Self.elapsed(waitBegan)}
      if let info {
        let execution=info.kernelExecutionTime,compile=info.kernelCompileTime
        v.kernelExecutionSeconds=execution.isFinite && execution>=0 ? execution:nil
        v.kernelCompileSeconds=compile.isFinite && compile>=0 ? compile:nil
        v.passes=info.passCount>=0 ? info.passCount:nil;v.pixelsProcessed=info.pixelsProcessed>=0 ? info.pixelsProcessed:nil
      }
      if purpose == .fitCheck{p.fitTask=v}else{p.outputTask=v}
    }
    func finish(successful:Bool)->IPPacket{p.successful=successful;return p}
  }
  static func ipTimingEnabled(bundleIdentifier:String?,environment:[String:String])->Bool {
    enabled(bundleIdentifier:bundleIdentifier,environment:environment) && environment["RAWMASTER_QA_IP_PHASES_V1"]=="1"
  }
  private static let ipTimingActive=ipTimingEnabled(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
  static func makeIPTiming(id:UUID,eligible:Bool)->IPTiming? {
    guard eligible,let sink,ipTimingActive else{return nil}
    return sink.makeIPTiming(id:id)
  }
  /// Called after actual detached return + ordinary join/retirement. No CI object reaches here.
  static func emitIPTiming(_ packet:IPPacket?)->UInt64? {
    guard let packet,let sink else{return nil};let began=IPTiming.now();sink.recordIPTiming(packet)
    return IPTiming.elapsed(began) // synchronous preparation/enqueue only, not later utility disk I/O
  }
  static func record(_ kind:Kind,_ phase:Phase,id:UUID,request:DevelopmentPreviewRequest?=nil,sourceID:UUID?=nil,
                     raw:RawBaseStatisticsSnapshot?=nil,stats:PreviewStatistics?=nil,
                     thumbnails:DevelopmentThumbnailStatistics?=nil,receipt:PreviewNativePointwiseReceiptV1?=nil,frameID:UUID?=nil,ipEmitNS:UInt64?=nil,
                     sharedFITRequested:Bool?=nil,bitmapReplay:Bool=false,grainFinalTransport:String?=nil,presentationTicketID:UUID?=nil,thumbnailStep:ThumbnailStep?=nil) {
    guard let sink else{return}
    sink.record(kind,phase,id:id,request:request,sourceID:sourceID,raw:raw,stats:stats,thumbnails:thumbnails,receipt:receipt,frameID:frameID,ipEmitNS:ipEmitNS,sharedFITRequested:sharedFITRequested,bitmapReplay:bitmapReplay,grainFinalTransport:grainFinalTransport,presentationTicketID:presentationTicketID,thumbnailStep:thumbnailStep)
  }
  static func freshSharedFITInsertion(receipt: PreviewNativePointwiseReceiptV1?, bitmapReplay: Bool) -> Bool {
    !bitmapReplay && receipt?.sharedFITIntermediateInserted == true
  }
  static func recordMainOwner(_ record: PreviewQAMainPresentationWitness.Record) { sink?.recordMainOwner(record) }
  static func recordThumbnailContext(_ record:ThumbnailWorkerContextV1.Record){sink?.recordThumbnailContext(record)}
  static func flush(){sink?.flush()}
  private final class Sink:@unchecked Sendable {
    let url:URL
    let writer=DispatchQueue(label:"RAWMaster.qa022-worker-phases",qos:.utility)
    let lock=NSLock()
    var limit=Limit()
    private var ipJobLimit=IPJobLimit()
    let device=MTLCreateSystemDefaultDevice()
    init(url:URL){self.url=url}
    func record(_ kind:Kind,_ phase:Phase,id:UUID,request:DevelopmentPreviewRequest?,sourceID:UUID?,raw:RawBaseStatisticsSnapshot?,
                stats:PreviewStatistics?,thumbnails:DevelopmentThumbnailStatistics?,receipt:PreviewNativePointwiseReceiptV1?,frameID:UUID?,ipEmitNS:UInt64?,sharedFITRequested:Bool?,bitmapReplay:Bool,grainFinalTransport:String?,presentationTicketID:UUID?,thumbnailStep:ThumbnailStep?) {
      lock.lock();let overflow=limit.reserve();lock.unlock();guard let overflow else{return}
      let now=DispatchTime.now().uptimeNanoseconds
      var row:[String:Any]=["event":"qa022.worker","atNS":now,"kind":kind.rawValue,"phase":phase.rawValue,"phaseID":id.uuidString]
      if overflow {row=["event":"qa022.overflow","atNS":now,"limit":4096]}
      else {
        if let thumbnailStep { row["thumbnailStep"]=thumbnailStep.rawValue }
        if let sourceID{row["sourceOwnerID"]=sourceID.uuidString}
        if let request {row["sessionID"]=request.sessionID.rawValue.uuidString;row["consumerID"]=request.consumerID.rawValue.uuidString;row["sourceGeneration"]=request.sourceGeneration;row["revision"]=request.revision;row["quality"]=request.quality.rawValue;row["role"]=request.role.rawValue}
        if let frameID {
          row["frameID"]=frameID.uuidString
          if let presentationTicketID {row["presentationTicketID"]=presentationTicketID.uuidString}
          row["sharedFITRequested"]=sharedFITRequested ?? false
          row["bitmapReplay"]=bitmapReplay
          row["sharedFITIntermediateInserted"] = PreviewQALifecycleTrace.freshSharedFITInsertion(receipt:receipt,bitmapReplay:bitmapReplay)
          if let transport=receipt?.canonicalNaturalFITTransport{row["canonicalNaturalFITTransport"]=transport}
          if let transport=grainFinalTransport ?? receipt?.canonicalGrainFinalTransport{row["canonicalGrainFinalTransport"]=transport}
        }
        if let ipEmitNS{row["ipTimingEmitEnqueueWallNanoseconds"]=ipEmitNS}
        var info=task_vm_info_data_t();var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&info){pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
        row["physFootprintBytes"]=status==KERN_SUCCESS ? info.phys_footprint as Any:NSNull()
        if let device {row["metalAPIAllocatedBytes"]=device.currentAllocatedSize}else{row["metalAPIAllocatedBytes"]=NSNull()}
        let p=PreviewPresentationLedger.shared.statistics
        row["presentationCPUBytes"]=p.chargedCPUBytes;row["presentationGPUAliasSubsetBytes"]=p.chargedGPUBytes;row["presentationRetiredCPUBytes"]=p.retiredCPUBytes
        if let raw {row["rawResidentBytes"]=raw.residentBytes;row["rawReservedBytes"]=raw.reservedBytes;row["rawBuildingBytes"]=raw.buildingBytes;row["rawPinnedBytes"]=raw.pinnedBytes;row["rawRetiredBytes"]=raw.retiredBytes;row["rawFills"]=raw.fills;row["rawHits"]=raw.hits;row["rawMisses"]=raw.misses;row["rawEvictions"]=raw.evictions}
        if let stats {row["cachedBitmapBytes"]=stats.cachedBitmapBytes;row["rawResidentActorBytes"]=stats.rawBaseResidentBytes;row["activeNativeRenders"]=stats.activeNativeRenders;row["pendingRequests"]=stats.pendingRequests;row["nativeNaturalProvenGlobalOutputs"]=stats.nativeNaturalProvenGlobalOutputs;row["nativeNaturalProvenBitmapHits"]=stats.nativeNaturalProvenBitmapHits;row["nativeProfileInteractiveJobs"]=stats.nativeProfileInteractiveJobs;row["nativeProfileCanonicalValidatedOutputs"]=stats.nativeProfileCanonicalValidatedOutputs;row["nativeProfileCanonicalProvenGlobalOutputs"]=stats.nativeProfileCanonicalProvenGlobalOutputs;row["nativeProfileCanonicalProvenBitmapHits"]=stats.nativeProfileCanonicalProvenBitmapHits}
        if let t=thumbnails {row["thumbnailCPUBytes"]=t.cpuBytes;row["thumbnailGPUBytes"]=t.gpuBytes;row["thumbnailUnionBytes"]=t.unionBytes;row["thumbnailReservedBytes"]=t.reservedBytes;row["thumbnailInFlightBytes"]=t.inFlightBytes;row["thumbnailRetiredBytes"]=t.retiredBytes;row["thumbnailManagedBackingBytes"]=t.managedBackingBytes;row["thumbnailRetiredManagedBackingBytes"]=t.retiredManagedBackingBytes}
        row["nativeReceiptObserved"]=receipt != nil
        if let r=receipt {row["certified"]=r.certified;row["proofID"]=r.proofID;row["canonicalFullChecks"]=r.canonicalFullChecks;row["canonicalGlobalFiniteProofID"]=r.canonicalGlobalFiniteProofID as Any? ?? NSNull();row["canonicalGlobalFiniteBinding"]=r.canonicalGlobalFiniteBinding as Any? ?? NSNull();row["canonicalGlobalFiniteStage"]=r.canonicalGlobalFiniteStage as Any? ?? NSNull();row["canonicalProofFITChecked"]=r.canonicalProofFITChecked;row["canonicalNaturalLUTSHA256"]=r.canonicalNaturalLUTSHA256 as Any? ?? NSNull();row["canonicalNaturalGlobalScans"]=r.canonicalNaturalGlobalScans as Any? ?? NSNull();row["canonicalNaturalProofConsumptions"]=r.canonicalNaturalProofConsumptions as Any? ?? NSNull();row["canonicalNaturalSynthetic"]=r.canonicalNaturalSynthetic;row["sourceCold"]=r.sourceCold;row["samplerCold"]=r.samplerCold;if let n=r.fullNativeChecks{row["fullNativeChecks"]=n}else{row["fullNativeChecks"]=NSNull()};if let owner=r.owner{row["nativeInputOwnerID"]=owner.uuidString}else{row["nativeInputOwnerID"]=NSNull()}}
      }
      guard let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys)else{return}
      var line=data;line.append(10)
      writer.async{[self,line]in
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0o600);guard fd>=0 else{return};defer{Darwin.close(fd)}
        line.withUnsafeBytes{bytes in var offset=0;while offset<bytes.count{let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if n<=0{break};offset+=n}}
      }
    }
    func makeIPTiming(id:UUID)->IPTiming? {
      lock.lock();defer{lock.unlock()};guard let ordinal=ipJobLimit.reserve()else{return nil}
      return IPTiming(id:id,ordinal:ordinal)
    }
    func recordIPTiming(_ packet:IPPacket) {
      lock.lock();let overflow=limit.reserve();lock.unlock();guard let overflow else{return}
      let row:[String:Any]=overflow ? ["event":"qa022.overflow","atNS":IPTiming.now(),"limit":4096]:packet.fields()
      guard let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys)else{return}
      var line=data;line.append(10)
      writer.async{[self,line]in
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0o600);guard fd>=0 else{return};defer{Darwin.close(fd)}
        line.withUnsafeBytes{bytes in var offset=0;while offset<bytes.count{let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if n<=0{break};offset+=n}}
      }
    }
    func recordMainOwner(_ record: PreviewQAMainPresentationWitness.Record) {
      lock.lock(); let overflow=limit.reserve(); lock.unlock(); guard let overflow else{return}
      let data: Data?
      if overflow {data=try? JSONSerialization.data(withJSONObject:["event":"qa022.overflow","atNS":IPTiming.now(),"limit":4096],options:.sortedKeys)}
      else {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];data=try? encoder.encode(record)}
      guard var line=data else{return};line.append(10)
      writer.async{[self,line]in
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0o600);guard fd>=0 else{return};defer{Darwin.close(fd)}
        line.withUnsafeBytes{bytes in var offset=0;while offset<bytes.count{let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if n<=0{break};offset+=n}}
      }
    }
    func recordThumbnailContext(_ record:ThumbnailWorkerContextV1.Record) {
      lock.lock();let overflow=limit.reserve();lock.unlock();guard let overflow else{return}
      let data:Data?
      if overflow{data=try? JSONSerialization.data(withJSONObject:["event":"qa022.overflow","atNS":IPTiming.now(),"limit":4096],options:.sortedKeys)}
      else{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];data=try? encoder.encode(record)}
      guard var line=data else{return};line.append(10)
      writer.async{[self,line]in
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0o600);guard fd>=0 else{return};defer{Darwin.close(fd)}
        line.withUnsafeBytes{bytes in var offset=0;while offset<bytes.count{let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if n<=0{break};offset+=n}}
      }
    }
    func flush(){writer.sync{let fd=Darwin.open(url.path,O_WRONLY|O_APPEND|O_NOFOLLOW);if fd>=0{_ = Darwin.fsync(fd);Darwin.close(fd)}}}
  }
}
