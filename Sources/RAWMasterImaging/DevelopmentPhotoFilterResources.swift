import Foundation
import CoreImage
import CryptoKit
import Metal
import Darwin
import RAWMasterCore

enum DevelopmentPhotoFilterError: Error, Equatable, Sendable {
  case catalogUnavailable, invalidCatalog, invalidPayload, unavailableFilter, unavailableDevice, budgetUnavailable, invalidGraph
}

/// Own numeric LUT allocations, not RAW/photo pixels or CI's private rendering intermediates.
/// All ready/active/retiring/loading charges share one process-wide32MiB cap, including exports.
final class DevelopmentPhotoFilterCharge {
  enum State { case loading, ready, active, retiring }
  private static let lock=NSLock()
  private static var entries:[UUID:(Int,State)]=[:]
  static let maximumBytes=32*1024*1024
  let id=UUID()
  private var registered=false
  init(bytes:Int,state:State) throws {
    guard bytes>0 else { throw DevelopmentPhotoFilterError.budgetUnavailable }
    Self.lock.lock();defer{Self.lock.unlock()}
    let used=Self.entries.values.reduce(0){$0+$1.0}
    guard bytes<=Self.maximumBytes-used else { throw DevelopmentPhotoFilterError.budgetUnavailable }
    Self.entries[id]=(bytes,state);registered=true
  }
  func grow(to bytes:Int)throws {
    Self.lock.lock();defer{Self.lock.unlock()}
    guard let old=Self.entries[id],bytes>=old.0 else { throw DevelopmentPhotoFilterError.budgetUnavailable }
    let used=Self.entries.values.reduce(0){$0+$1.0}
    guard bytes-old.0<=Self.maximumBytes-used else { throw DevelopmentPhotoFilterError.budgetUnavailable }
    Self.entries[id]=(bytes,old.1)
  }
  func state(_ value:State) {
    Self.lock.lock();defer{Self.lock.unlock()}
    if let old=Self.entries[id] { Self.entries[id]=(old.0,value) }
  }
  deinit {
    guard registered else{return};Self.lock.lock();Self.entries.removeValue(forKey:id);Self.lock.unlock()
  }
  struct Snapshot { let union,loading,ready,active,retiring:Int }
  static func snapshot()->Snapshot {
    lock.lock();defer{lock.unlock()}
    var loading=0,ready=0,active=0,retiring=0
    for (bytes,state) in entries.values {
      switch state {case .loading:loading+=bytes;case .ready:ready+=bytes;case .active:active+=bytes;case .retiring:retiring+=bytes}
    }
    return .init(union:loading+ready+active+retiring,loading:loading,ready:ready,active:active,retiring:retiring)
  }
}

struct DevelopmentPhotoFilterPayload: Codable {
  let intensityPercent:Int
  let file:String
  let byteCount:Int
  let sha256:String
}
struct DevelopmentPhotoFilterLook: Codable {
  let id:DevelopmentPhotoFilterV3
  let planes:[DevelopmentPhotoFilterPayload]
}
struct DevelopmentPhotoFilterCatalog: Codable {
  let schemaVersion:Int
  let operatorVersion,representation:String
  let cubeDimension,atlasWidth,atlasHeight:Int
  let axisCodes:[UInt16]
  let inputICCsha256,alphaPolicy,hdrPolicy,sourceBindingsSHA256,builderSHA256:String
  let looks:[DevelopmentPhotoFilterLook]
  static let payloadBytes=64*64*64*16
  static let intensities=[1,25,50,100]
  static let icc="2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e"
  static func filename(_ look:DevelopmentPhotoFilterV3,_ percent:Int)->String { "\(look.rawValue)-\(String(format:"%03d",percent)).delta64.rgba32f" }
  static func decode(_ data:Data)throws->Self {
    guard data.count<=65536 else{throw DevelopmentPhotoFilterError.invalidCatalog}
    let object:Any
    do{object=try JSONSerialization.jsonObject(with:data)}catch{throw DevelopmentPhotoFilterError.invalidCatalog}
    guard let top=object as? [String:Any] else{throw DevelopmentPhotoFilterError.invalidCatalog}
    let keys:Set<String>=["schemaVersion","operatorVersion","representation","cubeDimension","atlasWidth","atlasHeight","axisCodes","inputICCsha256","alphaPolicy","hdrPolicy","sourceBindingsSHA256","builderSHA256","looks"]
    guard Set(top.keys)==keys,let rawLooks=top["looks"] as? [[String:Any]],(1...9).contains(rawLooks.count) else {throw DevelopmentPhotoFilterError.invalidCatalog}
    for look in rawLooks {
      guard Set(look.keys)==["id","planes"],let planes=look["planes"] as? [[String:Any]],planes.count==4 else {throw DevelopmentPhotoFilterError.invalidCatalog}
      for plane in planes { guard Set(plane.keys)==["intensityPercent","file","byteCount","sha256"] else {throw DevelopmentPhotoFilterError.invalidCatalog} }
    }
    let value:Self
    do{value=try JSONDecoder().decode(Self.self,from:data)}catch{throw DevelopmentPhotoFilterError.invalidCatalog}
    let axis=(0..<64).map{UInt16((65535*$0+31)/63)}
    guard value.schemaVersion==1,value.operatorVersion==DevelopmentPhotoFilterEngineV3.operatorVersion,
      value.representation=="linear-delta64-rgba32f-v1",value.cubeDimension==64,value.atlasWidth==512,value.atlasHeight==512,
      value.axisCodes==axis,value.inputICCsha256==icc,
      value.alphaPolicy=="source-alpha-preserved/lowalpha-1over65535-bypass",value.hdrPolicy=="boundary-residual-mono-noir-endpoint-v2",
      EditingFingerprint.isSHA256(value.sourceBindingsSHA256),EditingFingerprint.isSHA256(value.builderSHA256),
      Set(value.looks.map(\.id)).count==value.looks.count else {throw DevelopmentPhotoFilterError.invalidCatalog}
    for look in value.looks {
      guard look.id != .original,look.planes.map(\.intensityPercent).sorted()==intensities else {throw DevelopmentPhotoFilterError.invalidCatalog}
      for p in look.planes {
        guard p.byteCount==payloadBytes,p.file==filename(look.id,p.intensityPercent),EditingFingerprint.isSHA256(p.sha256) else {throw DevelopmentPhotoFilterError.invalidCatalog}
      }
    }
    return value
  }
}

fileprivate enum FilterResourceIO {
  struct Stamp:Equatable {
    let device:Int32,inode:UInt64,size:Int64,seconds:Int,nanos:Int,changed:Int,changedNanos:Int
    init(_ s:stat){device=s.st_dev;inode=s.st_ino;size=s.st_size;seconds=s.st_mtimespec.tv_sec;nanos=s.st_mtimespec.tv_nsec;changed=s.st_ctimespec.tv_sec;changedNanos=s.st_ctimespec.tv_nsec}
  }
  static func openFile(_ url:URL)throws->(Int32,Stamp) {
    let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW)
    guard fd>=0 else{throw DevelopmentPhotoFilterError.invalidPayload}
    var s=stat()
    guard Darwin.fstat(fd,&s)==0,s.st_mode&S_IFMT==S_IFREG else{Darwin.close(fd);throw DevelopmentPhotoFilterError.invalidPayload}
    return(fd,Stamp(s))
  }
  static func stamp(_ url:URL)throws->Stamp {let(fd,s)=try openFile(url);Darwin.close(fd);return s}
  static func readCatalog(_ url:URL)throws->(Data,Stamp) {
    let(fd,before)=try openFile(url);defer{Darwin.close(fd)}
    guard before.size>0,before.size<=65536 else{throw DevelopmentPhotoFilterError.invalidCatalog}
    var data=Data(count:Int(before.size))
    try data.withUnsafeMutableBytes { b in try readExactly(fd,b.baseAddress!,b.count) }
    guard try stamp(url)==before else{throw DevelopmentPhotoFilterError.invalidCatalog}
    return(data,before)
  }
  static func readExactly(_ fd:Int32,_ address:UnsafeMutableRawPointer,_ count:Int)throws {
    var done=0
    while done<count {
      let n=Darwin.read(fd,address.advanced(by:done),count-done)
      if n<0 && errno==EINTR{continue}
      guard n>0 else{throw DevelopmentPhotoFilterError.invalidPayload};done+=n
    }
  }
  ///64KiB scratch is charged too. Payload memory is never a second whole Data/F32 array.
  static func payload(_ url:URL,record:DevelopmentPhotoFilterPayload,destination:UnsafeMutableRawPointer?=nil,expected:Stamp?=nil)throws->Stamp {
    let(fd,before)=try openFile(url);defer{Darwin.close(fd)}
    guard before.size==Int64(record.byteCount),expected==nil || expected==before else{throw DevelopmentPhotoFilterError.invalidPayload}
    let bytes=65536,reserved=malloc_good_size(bytes)
    let scratch=try DevelopmentPhotoFilterCharge(bytes:reserved,state:.loading)
    guard let pointer=malloc(reserved) else{throw DevelopmentPhotoFilterError.budgetUnavailable}
    defer{free(pointer);withExtendedLifetime(scratch){}}
    guard malloc_size(pointer)<=reserved else{throw DevelopmentPhotoFilterError.budgetUnavailable}
    var digest=SHA256(),offset=0
    while offset<record.byteCount {
      try Task.checkCancellation()
      let count=min(bytes,record.byteCount-offset)
      try readExactly(fd,pointer,count)
      for i in stride(from:0,to:count,by:16) {
        for c in 0..<4 {
          let bits=pointer.loadUnaligned(fromByteOffset:i+c*4,as:UInt32.self).littleEndian
          let value=Float(bitPattern:bits)
          guard c==3 ? bits==0x3f800000:(value.isFinite && abs(value)<=1) else{throw DevelopmentPhotoFilterError.invalidPayload}
        }
      }
      digest.update(data:Data(bytesNoCopy:pointer,count:count,deallocator:.none))
      if let destination{memcpy(destination.advanced(by:offset),pointer,count)}
      offset+=count
    }
    let actual=digest.finalize().map{String(format:"%02x",$0)}.joined()
    guard actual==record.sha256,try stamp(url)==before else{throw DevelopmentPhotoFilterError.invalidPayload}
    return before
  }
}

/// Last backing owner is the MTLBuffer deallocator, not an LRU dictionary or Swift graph wrapper.
final class DevelopmentPhotoFilterAtlas {
  let image:CIImage
  let buffer:MTLBuffer
  let texture:MTLTexture
  let charge:DevelopmentPhotoFilterCharge
  let bytes:Int
  fileprivate init(url:URL,record:DevelopmentPhotoFilterPayload,stamp:FilterResourceIO.Stamp,device:MTLDevice)throws {
    let row=512*16,page=Int(getpagesize()),length=((row*512+page-1)/page)*page
    guard row%max(256,device.minimumLinearTextureAlignment(for:.rgba32Float))==0 else{throw DevelopmentPhotoFilterError.unavailableDevice}
    let charge=try DevelopmentPhotoFilterCharge(bytes:length,state:.loading)
    var pointer:UnsafeMutableRawPointer?
    guard posix_memalign(&pointer,page,length)==0,let pointer else{throw DevelopmentPhotoFilterError.budgetUnavailable}
    var handedOff=false
    defer{if !handedOff{free(pointer)}}
    try charge.grow(to:max(length,malloc_size(pointer)))
    _=try FilterResourceIO.payload(url,record:record,destination:pointer,expected:stamp)
    guard let b=device.makeBuffer(bytesNoCopy:pointer,length:length,options:.storageModeShared,deallocator:{p,_ in free(p);withExtendedLifetime(charge){}}) else{throw DevelopmentPhotoFilterError.unavailableDevice}
    handedOff=true
    try charge.grow(to:max(length,max(malloc_size(pointer),b.allocatedSize)))
    let description=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:512,height:512,mipmapped:false)
    description.storageMode = .shared;description.usage = .shaderRead
    guard let texture=b.makeTexture(descriptor:description,offset:0,bytesPerRow:row),
      let image=CIImage(mtlTexture:texture,options:[.colorSpace:NSNull()]) else{throw DevelopmentPhotoFilterError.invalidGraph}
    self.buffer=b;self.texture=texture;self.image=image;self.charge=charge;bytes=max(length,max(malloc_size(pointer),b.allocatedSize));charge.state(.ready)
  }
  func published(){charge.state(.active)}
  deinit{charge.state(.retiring)}
}

final class DevelopmentPhotoFilterResourceStore: @unchecked Sendable {
  /// SwiftPM copies this folder at the resource bundle root; the App copies the same bundle.
  /// No build-path fallback: a missing/invalid installed resource means only Original.
  static func installedAppResourceRoot(resourcesURL:URL?)->URL? {
    guard let resourcesURL,
      let bundle=Bundle(url:resourcesURL.appendingPathComponent("RAWMaster_RAWMasterImaging.bundle",isDirectory:true)) else{return nil}
    return bundle.url(forResource:"PhotoFilters",withExtension:nil)
  }
  static let bundledRoot:URL? = {
    if Bundle.main.bundleURL.pathExtension.lowercased()=="app" {
      // Bundle.module's generated development fallback must not rescue a broken installed App.
      return installedAppResourceRoot(resourcesURL:Bundle.main.resourceURL)
    }
    return Bundle.module.url(forResource:"PhotoFilters",withExtension:nil)
  }()
  static let shared=DevelopmentPhotoFilterResourceStore(resourceRoot:bundledRoot)
  struct Capabilities {let filters:Set<DevelopmentPhotoFilterV3>;let resourceVersion:String?}
  struct Pair {let lower,upper:DevelopmentPhotoFilterAtlas;let weight:Float;let zeroLower:Bool;let version:String}
  private struct Verified {let look:DevelopmentPhotoFilterLook;let stamps:[Int:FilterResourceIO.Stamp]}
  private struct CatalogState {let stamp:FilterResourceIO.Stamp;let version:String;var valid:[DevelopmentPhotoFilterV3:Verified]}
  private let lock=NSLock()
  private let root:URL?
  private let device:MTLDevice?
  private var state:CatalogState?
  private var failed=false
  private var cache:[String:DevelopmentPhotoFilterAtlas]=[:]
  private var recent:[String:UInt64]=[:]
  private var sequence:UInt64=0
  private let readyTarget=16*1024*1024
  init(resourceRoot:URL?,device:MTLDevice?=nil){root=resourceRoot?.standardizedFileURL.resolvingSymlinksInPath();self.device=device}
  private func invalidate(){state=nil;failed=true;cache.removeAll();recent.removeAll()}
  private func catalog(validating selection:DevelopmentPhotoFilterV3? = nil)throws->CatalogState {
    guard !failed,let root else{throw DevelopmentPhotoFilterError.catalogUnavailable}
    if let state {
      guard try FilterResourceIO.stamp(root.appendingPathComponent("catalog-v1.json"))==state.stamp else{invalidate();throw DevelopmentPhotoFilterError.invalidCatalog}
      var current=state
      // Capability discovery rechecks every advertised look. A render or bitmap replay
      // requires the catalog and all four verified planes of the actual selected look.
      for (look,verified) in state.valid where selection == nil || selection == look {
        do {
          for p in verified.look.planes {guard try FilterResourceIO.stamp(root.appendingPathComponent(p.file))==verified.stamps[p.intensityPercent] else{throw DevelopmentPhotoFilterError.invalidPayload}}
        }catch{current.valid.removeValue(forKey:look);cache.removeAll();recent.removeAll()}
      }
      self.state=current;return current
    }
    let(data,stamp)=try FilterResourceIO.readCatalog(root.appendingPathComponent("catalog-v1.json"))
    let parsed=try DevelopmentPhotoFilterCatalog.decode(data)
    var valid:[DevelopmentPhotoFilterV3:Verified]=[:]
    for look in parsed.looks {
      do {
        var stamps:[Int:FilterResourceIO.Stamp]=[:]
        for p in look.planes {stamps[p.intensityPercent]=try FilterResourceIO.payload(root.appendingPathComponent(p.file),record:p)}
        valid[look.id]=Verified(look:look,stamps:stamps)
      }catch is CancellationError{throw CancellationError()}
      catch DevelopmentPhotoFilterError.budgetUnavailable{throw DevelopmentPhotoFilterError.budgetUnavailable}
      catch{continue} // A corrupt/missing look is NOT advertised; no fallback pixels.
    }
    let version=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    let result=CatalogState(stamp:stamp,version:version,valid:valid);state=result;return result
  }
  func capabilities()->Capabilities {
    lock.lock();defer{lock.unlock()}
    do{let value=try catalog();return .init(filters:Set(value.valid.keys).union([.original]),resourceVersion:value.valid.isEmpty ? nil:value.version)}
    catch{return .init(filters:[.original],resourceVersion:nil)}
  }
  func validate(_ filter:DevelopmentFilterV3)throws {
    _ = try resourceVersion(for:filter)
  }
  func resourceVersion(for filter:DevelopmentFilterV3)throws->String? {
    try filter.validate();guard filter.enabled,filter.selection != .original,filter.intensity != 0 else{return nil}
    lock.lock();defer{lock.unlock()}
    let verified=try catalog(validating:filter.selection)
    guard verified.valid[filter.selection] != nil else{throw DevelopmentPhotoFilterError.unavailableFilter}
    return verified.version
  }
  private func trim(excluding:Set<String>,all:Bool=false) {
    var used=cache.values.reduce(0){$0+$1.bytes}
    for key in recent.keys.sorted(by:{recent[$0,default:0]<recent[$1,default:0]}) where !excluding.contains(key) {
      if !all && used<=readyTarget{break}
      if let owner=cache.removeValue(forKey:key){used-=owner.bytes};recent.removeValue(forKey:key)
    }
  }
  func pair(_ filter:DevelopmentFilterV3)throws->Pair {
    try filter.validate()
    guard filter.enabled,filter.selection != .original,filter.intensity>0 else{throw DevelopmentPhotoFilterError.unavailableFilter}
    lock.lock();defer{lock.unlock()}
    guard let root else{throw DevelopmentPhotoFilterError.catalogUnavailable}
    guard let device=device ?? MTLCreateSystemDefaultDevice() else{throw DevelopmentPhotoFilterError.unavailableDevice}
    let catalog=try catalog(validating:filter.selection);guard let verified=catalog.valid[filter.selection] else{throw DevelopmentPhotoFilterError.unavailableFilter}
    let percents=DevelopmentPhotoFilterCatalog.intensities
    let high=percents.first(where:{Double($0)>=filter.intensity}) ?? 100
    let low=percents.last(where:{Double($0)<filter.intensity}) ?? 0
    let exact=Double(high)==filter.intensity
    let lowerPercent=exact ? high:(low==0 ? high:low)
    let needed=Set([lowerPercent,high])
    let records=verified.look.planes.filter{needed.contains($0.intensityPercent)}
    func key(_ p:DevelopmentPhotoFilterPayload)->String{"\(device.registryID):\(p.sha256)"}
    let keep=Set(records.map(key));var created=[String]()
    do{
      for p in records where cache[key(p)]==nil {
        let name=key(p)
        do{cache[name]=try DevelopmentPhotoFilterAtlas(url:root.appendingPathComponent(p.file),record:p,stamp:verified.stamps[p.intensityPercent]!,device:device)}
        catch DevelopmentPhotoFilterError.budgetUnavailable {
          trim(excluding:keep,all:true)
          cache[name]=try DevelopmentPhotoFilterAtlas(url:root.appendingPathComponent(p.file),record:p,stamp:verified.stamps[p.intensityPercent]!,device:device)
        }
        created.append(name)
      }
      for p in records{sequence&+=1;recent[key(p)]=sequence}
      trim(excluding:keep)
      guard let lowRecord=records.first(where:{$0.intensityPercent==lowerPercent}),let highRecord=records.first(where:{$0.intensityPercent==high}),
        let a=cache[key(lowRecord)],let b=cache[key(highRecord)] else{throw DevelopmentPhotoFilterError.invalidPayload}
      a.published();b.published()
      // Below1percent both references alias one table: weight is direct Delta0→Delta1 scale.
      let weight:Float=exact ? 0:Float((filter.intensity-Double(low))/Double(high-low))
      return .init(lower:a,upper:b,weight:weight,zeroLower:low==0 && !exact,version:catalog.version)
    }catch{
      for k in created{cache.removeValue(forKey:k);recent.removeValue(forKey:k)}
      throw error // No wait/spin for a CI graph retained by this very caller.
    }
  }
  func trimReady(){lock.lock();cache.removeAll();recent.removeAll();lock.unlock()}
}
