import Foundation
import CoreImage
import RAWMasterCore

struct PreviewInteractiveInputDescriptor:Encodable {
  let version:String
  let sourceKey,verifiedContentID:String
  let captureID:UUID
  let generation:UInt64
  let device:Int32,inode:UInt64,byteCount:Int64
  let seconds,nanos,changedSeconds,changedNanos:Int
  let decoder,originalDefaults,nativeContract:String
  /// Identifies the actual cached base producer, independently of RAW adjustment semantics.
  let proxyDecoder:String
  var usesFlashRaw:Bool{proxyDecoder=="flashraw-linear-f16-metal-v1"}
  let sourceIsRAW:Bool
  let orientation,width,height:Int
  let extentXBits,extentYBits,scaleBits:UInt64
  let proxyWidth,proxyHeight,rowBytes:Int
  let nativeExposureBits:UInt32?
  let whiteBalanceMode:String
  let nativeTemperatureBits,nativeTintBits:UInt32?
  let nativeNoise:DevelopmentRAWNoiseReductionParametersV3?
  var scale:Double{Double(bitPattern:scaleBits)}
  var nativeSize:CGSize{CGSize(width:width,height:height)}
  var proxySize:CGSize{CGSize(width:proxyWidth,height:proxyHeight)}
  var contentRect:CGRect{CGRect(x:0,y:0,width:Double(width)*scale,height:Double(height)*scale)}
  func fingerprint()throws->String{try EditingFingerprint.of(self)}
}

/// One Service owns this pool; one existing native worker builds/renders. Retirement may be
/// requested by the actor while its sole worker is pinned: physical storage still belongs to Pin.
final class PreviewInteractiveProxyPool:@unchecked Sendable {
  final class Entry {
    let descriptor:PreviewInteractiveInputDescriptor,storage:PreviewInteractiveProxyStorage
    var pins=0,retired=false
    init(_ descriptor:PreviewInteractiveInputDescriptor,_ storage:PreviewInteractiveProxyStorage){self.descriptor=descriptor;self.storage=storage}
  }
  final class Pin {
    fileprivate let entry:Entry
    private let pool:PreviewInteractiveProxyPool
    var descriptor:PreviewInteractiveInputDescriptor{entry.descriptor}
    var storage:PreviewInteractiveProxyStorage{entry.storage}
    fileprivate init(_ entry:Entry,_ pool:PreviewInteractiveProxyPool){self.entry=entry;self.pool=pool}
    func check()throws{pool.lock.lock();let retired=entry.retired;pool.lock.unlock();if retired{throw PreviewPresentationError.closed}}
    deinit{pool.lock.lock();entry.pins-=1;pool.lock.unlock()}
  }
  struct Statistics:Sendable {let fills,hits,retiredInputs:Int;let residentBytes,pinnedBytes:Int;let owned:PreviewPresentationStatistics}
  fileprivate let lock=NSLock()
  private var entries:[String:Entry]=[:],fills=0,hits=0,retiredInputs=0
  private var building:(id:UUID,sourceKey:String,generation:UInt64,revoked:Bool,storage:PreviewInteractiveProxyStorage?)?
  func lookup(_ descriptor:PreviewInteractiveInputDescriptor)throws->Pin? {
    let key=try descriptor.fingerprint();lock.lock();defer{lock.unlock()}
    guard let entry=entries[key],!entry.retired else{return nil}
    entry.pins+=1;hits+=1;return Pin(entry,self)
  }
  func beginBuild(_ descriptor:PreviewInteractiveInputDescriptor)throws->UUID {
    lock.lock();defer{lock.unlock()};guard building==nil else{throw PreviewPresentationError.allocationProtocol}
    let id=UUID();building=(id,descriptor.sourceKey,descriptor.generation,false,nil);return id
  }
  func attachBuildingStorage(_ storage:PreviewInteractiveProxyStorage,id:UUID)throws {
    lock.lock();defer{lock.unlock()}
    guard building?.id==id,building?.revoked==false else{storage.markRetired();throw PreviewPresentationError.closed}
    building?.storage=storage
  }
  func endBuild(_ id:UUID){lock.lock();if building?.id==id{building=nil};lock.unlock()}
  func evictUnpinnedBeforeFill(){
    lock.lock();defer{lock.unlock()}
    for key in Array(entries.keys){guard let entry=entries[key],entry.pins==0 else{continue};entry.retired=true;entry.storage.markRetired();entries.removeValue(forKey:key);retiredInputs+=1}
  }
  func publish(_ descriptor:PreviewInteractiveInputDescriptor,_ storage:PreviewInteractiveProxyStorage,buildID:UUID)throws->Pin {
    let key=try descriptor.fingerprint();lock.lock();defer{lock.unlock()}
    guard entries[key]==nil,building?.id==buildID,building?.revoked==false else{storage.markRetired();throw PreviewPresentationError.closed}
    building=nil
    let entry=Entry(descriptor,storage);entry.pins=1;entries[key]=entry;fills+=1;return Pin(entry,self)
  }
  func retire(sourceKey:String?=nil,generation:UInt64?=nil){
    lock.lock();defer{lock.unlock()}
    if (sourceKey==nil || building?.sourceKey==sourceKey) && (generation==nil || building?.generation==generation){building?.revoked=true;building?.storage?.markRetired()}
    for key in Array(entries.keys){guard let entry=entries[key],(sourceKey==nil || entry.descriptor.sourceKey==sourceKey),(generation==nil || entry.descriptor.generation==generation) else{continue};entry.retired=true;entry.storage.markRetired();entries.removeValue(forKey:key);retiredInputs+=1}
  }
  func statistics(ledger:PreviewPresentationLedger = .shared)->Statistics {
    lock.lock();defer{lock.unlock()}
    return .init(fills:fills,hits:hits,retiredInputs:retiredInputs,residentBytes:entries.values.reduce(0){$0+$1.storage.layout.bytes},pinnedBytes:entries.values.filter{$0.pins>0}.reduce(0){$0+$1.storage.layout.bytes},owned:ledger.statistics)
  }
}
