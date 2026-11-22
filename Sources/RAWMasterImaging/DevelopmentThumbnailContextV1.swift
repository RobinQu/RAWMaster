import Foundation
import CoreImage
import Metal

/// One Service-owned wrapper, borrowed only by that Service's serial native worker.
/// The 2MiB reservation is conservative bookkeeping, not a bound on CI-private memory.
final class ThumbnailWorkerContextV1: @unchecked Sendable {
  static let reservedBytes=2*1024*1024
  struct Snapshot:Sendable {
    let ownerID:UUID,contextID:UUID?
    let creations,borrows,retirements,active:Int
    let reservedBytes:Int,quarantined:Bool,wrapperNil:Bool
  }
  struct Record:Encodable,Sendable {
    let event="qa022.thumbnail-context"
    let atNS:UInt64,ownerID:UUID,contextID:UUID?,phase:String
    let creations,borrows,retirements,active,reservedBytes:Int
    let quarantined,wrapperNil:Bool
  }
  private let lock=NSLock(),id=UUID()
  // Only the native borrow/maintenance executor accesses these, after acquiring busy.
  private var context:CIContext?,ticket:ThumbnailTicket?,deviceID:UInt64?
  private var contextID:UUID?,creations=0,borrows=0,retirements=0,busy=false,failed=false,hasContext=false,charged=false
  // At most one failure quarantine per Service owner. It can never create a replacement.
  // This intentional failure-only cycle keeps the ticket charged even if Service is released.
  private var failedRetirement:ThumbnailWorkerContextV1?
  var snapshot:Snapshot {
    lock.lock();defer{lock.unlock()}
    return .init(ownerID:id,contextID:contextID,creations:creations,borrows:borrows,retirements:retirements,
      active:busy ? 1:0,reservedBytes:charged ? Self.reservedBytes:0,quarantined:failed,wrapperNil:!hasContext)
  }
  private func record(_ phase:String) {
    guard PreviewQALifecycleTrace.isEnabled else{return}
    let s=snapshot
    PreviewQALifecycleTrace.recordThumbnailContext(.init(atNS:DispatchTime.now().uptimeNanoseconds,
      ownerID:s.ownerID,contextID:s.contextID,phase:phase,creations:s.creations,borrows:s.borrows,
      retirements:s.retirements,active:s.active,reservedBytes:s.reservedBytes,quarantined:s.quarantined,wrapperNil:s.wrapperNil))
  }
  func withContext<T>(ledger:ThumbnailLedger,device:MTLDevice,_ body:(CIContext)throws->T)throws->T {
    lock.lock()
    guard !busy,!failed,deviceID==nil || deviceID==device.registryID else{lock.unlock();throw DevelopmentThumbnailError.unavailableDevice}
    busy=true;lock.unlock()
    defer{lock.lock();busy=false;lock.unlock();record("borrow-return")}
    if context==nil {
      let reservation=try ledger.reserve(Self.reservedBytes,kind:.summary)
      let value=DevelopmentThumbnailEngine.context(device:device)
      context=value;ticket=reservation
      lock.lock();deviceID=device.registryID;contextID=UUID();creations+=1;hasContext=true;charged=true;lock.unlock()
      record("created")
    }
    lock.lock();borrows+=1;lock.unlock();record("borrow-enter")
    // cacheIntermediates is false; retain compiled programs until owner retirement.
    return try autoreleasepool {
      let value=context!
      return try body(value)
    }
  }
  /// Must run after the outer native worker has really joined; never from a borrow.
  /// A failed weak-wrapper witness preserves one failure reservation, without a retry/replacement.
  @discardableResult func retire()->Bool {
    lock.lock()
    guard !busy,!failed else{lock.unlock();return false}
    guard hasContext else{lock.unlock();return true}
    busy=true;lock.unlock();record("retire-begin")
    weak var witness:CIContext?
    autoreleasepool {
      let value=context!
      witness=value
      value.clearCaches()
      context=nil
    }
    let released=witness==nil
    lock.lock()
    hasContext = !released
    if released {retirements+=1;deviceID=nil}
    else {failed=true;failedRetirement=self}
    lock.unlock()
    if released {
      // Weak nil proves wrapper retirement only; private backend memory is separately sampled.
      record("wrapper-nil")
      ticket?.release();ticket=nil
      lock.lock();charged=false;lock.unlock()
    }else{ticket?.phase(.retired)}
    lock.lock();busy=false;lock.unlock()
    record(released ? "retire-end":"retire-quarantined")
    return released
  }
}
