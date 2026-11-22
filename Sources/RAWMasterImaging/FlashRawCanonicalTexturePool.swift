import CoreImage
import Foundation

struct FlashRawCanonicalTextureKey: Hashable {
  enum Representation:Hashable { case linearRGBA16F, guideR32F }
  let sourceKey: String
  let captureStamp: PreviewFileStamp
  let contract: String
  let width,height: Int
  var representation:Representation = .linearRGBA16F
  var deviceAllocationBytes: Int? = nil
  var byteCount: Int {
    let bytesPerPixel=representation == .guideR32F ? 4:8
    guard width > 0, height > 0, width <= Int.max / bytesPerPixel / height else { return 0 }
    return max(width * height * bytesPerPixel, deviceAllocationBytes ?? 0)
  }
}

struct FlashRawCanonicalTextureStatistics: Sendable {
  var residentBytes=0,pinnedBytes=0,hits=0,fills=0,evictions=0
  var peakReservedBytes = 0
}

/// Direct CIImage/MTLTexture ownership. No CV/IOSurface conversion is inserted.
/// The native worker serializes actual production acquisition; the lock also makes test/fixture use safe.
final class FlashRawCanonicalTexturePool: @unchecked Sendable {
  static let shared = FlashRawCanonicalTexturePool(byteBudget:
    Int(min(UInt64(1_073_741_824), ProcessInfo.processInfo.physicalMemory / 12)))
  fileprivate final class Entry {
    let image:CIImage
    let key:FlashRawCanonicalTextureKey
    var pins=0,retired=false,use:UInt64=0
    var nativeGlobalOutputWasFinite = false
    init(image:CIImage,key:FlashRawCanonicalTextureKey){self.image=image;self.key=key}
  }
  final class Pin {
    private static let reuseGlobalValidation = ProcessInfo.processInfo.environment["RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE"] != "1"
    let image:CIImage
    private let pool:FlashRawCanonicalTexturePool,key:FlashRawCanonicalTextureKey
    private var released=false
    fileprivate init(_ entry:Entry,pool:FlashRawCanonicalTexturePool){
      image=entry.image;self.pool=pool;key=entry.key
    }
    /// The decoder finishes the private RGBA16F texture before publishing its CIImage.
    /// Only that exact object, at the canonical global-output boundary, can reuse a scan.
    func validateNativeGlobalOutput(_ output: CIImage, cancellation: (() throws -> Void)?,
                                    validate: () throws -> Void) throws {
      guard Self.reuseGlobalValidation, key.representation == .linearRGBA16F, output === image else {
        return try validate()
      }
      let lookupStarted = DispatchTime.now().uptimeNanoseconds
      try Task.checkCancellation()
      try cancellation?()
      let alreadyChecked = pool.lock.withLock {
        guard !released, let entry = pool.entries[key], !entry.retired, entry.image === output else { return false }
        return entry.nativeGlobalOutputWasFinite
      }
      if alreadyChecked {
        let token = ImagePerformanceTelemetry.shared.begin(operation: "NativeGlobalFiniteReuse",
          stage: "已验证的同一原生纹理 · 全局输出", queue: "图像引擎", boundary: .apiReturn,
          startedAt: lookupStarted)
        ImagePerformanceTelemetry.shared.end(token)
        return
      }
      // Concurrent callers can independently complete the first scan. Failure, cancellation
      // and retirement leave the entry unproven. Never hold the pool lock across GPU work.
      try validate()
      try Task.checkCancellation()
      try cancellation?()
      pool.lock.withLock {
        guard !released, let entry = pool.entries[key], !entry.retired, entry.image === output else { return }
        entry.nativeGlobalOutputWasFinite = true
      }
    }
    func release(){
      pool.lock.lock();defer{pool.lock.unlock()}
      guard !released else{return};released=true
      guard let entry=pool.entries[key],entry.pins>0 else{return}
      entry.pins-=1;if entry.retired && entry.pins==0{pool.remove(key)}
    }
    deinit{release()}
  }
  private final class Reservation { var retired = false }
  private var pending: [FlashRawCanonicalTextureKey: Reservation] = [:]
  private let lock = NSCondition()
  private let byteBudget: Int, maximumEntries: Int
  func canHold(_ key: FlashRawCanonicalTextureKey) -> Bool { key.byteCount > 0 && key.byteCount <= byteBudget }
  private var entries:[FlashRawCanonicalTextureKey:Entry]=[:]
  private var tick:UInt64=0
  private var counters=FlashRawCanonicalTextureStatistics()
  init(byteBudget:Int=1_073_741_824,maximumEntries:Int=2){
    self.byteBudget=max(0,byteBudget);self.maximumEntries=max(1,maximumEntries)
  }
  func acquire(_ key: FlashRawCanonicalTextureKey, make: () throws -> CIImage) throws -> Pin {
    guard canHold(key) else { throw RawBaseCacheError.capacity }
    lock.lock()
    while pending[key] != nil { lock.wait() }
    if let entry = entries[key] {
      guard !entry.retired else { lock.unlock(); throw RawBaseCacheError.capacity }
      entry.pins += 1
      tick &+= 1
      entry.use = tick
      counters.hits += 1
      let pin = Pin(entry, pool: self)
      lock.unlock()
      return pin
    }
    while chargedBytes > byteBudget - key.byteCount || entries.count + pending.count >= maximumEntries {
      // A new set of slider inputs may replace a small guide. Keep the decoded sensor
      // texture while an unpinned derived guide can free the required space.
      let victim = entries.values.filter { $0.pins==0 }.min {
        if $0.key.representation != $1.key.representation { return $0.key.representation == .guideR32F }
        return $0.use < $1.use
      }
      guard let victim else {
        lock.unlock()
        throw RawBaseCacheError.capacity
      }
      remove(victim.key)
    }
    let reservation = Reservation()
    pending[key] = reservation
    counters.peakReservedBytes = max(counters.peakReservedBytes, chargedBytes)
    lock.unlock()

    // Creating the texture can demosaic an entire RAW. Keep snapshots, returns and
    // retirement responsive while this key owns its byte reservation.
    do {
      let image = try make()
      guard image.extent == CGRect(x: 0, y: 0, width: key.width, height: key.height) else {
        throw RawBaseCacheError.allocationProtocol
      }
      lock.lock()
      let entry = Entry(image: image, key: key)
      tick &+= 1
      entry.use = tick
      entry.pins = 1
      entry.retired = reservation.retired
      entries[key] = entry
      pending.removeValue(forKey: key)
      counters.fills += 1
      let pin = Pin(entry, pool: self)
      lock.broadcast()
      lock.unlock()
      return pin
    } catch {
      lock.lock()
      pending.removeValue(forKey: key)
      lock.broadcast()
      lock.unlock()
      throw error
    }
  }

  private var chargedBytes: Int {
    entries.keys.reduce(0) { $0 + $1.byteCount } + pending.keys.reduce(0) { $0 + $1.byteCount }
  }
  private func remove(_ key:FlashRawCanonicalTextureKey){
    guard let entry=entries[key],entry.pins==0 else{return}
    entries.removeValue(forKey:key);counters.evictions+=1
  }
  func retire(sourceKey: String? = nil) {
    lock.lock();defer{lock.unlock()}
    for (key, reservation) in pending where sourceKey == nil || key.sourceKey == sourceKey {
      reservation.retired = true
    }
    for key in Array(entries.keys) where sourceKey == nil || key.sourceKey == sourceKey {
      entries[key]?.retired=true;if entries[key]?.pins==0{remove(key)}
    }
  }
  func statistics()->FlashRawCanonicalTextureStatistics {
    lock.lock();defer{lock.unlock()}
    var result=counters;result.residentBytes=entries.values.filter{!$0.retired}.reduce(0){$0+$1.key.byteCount}
    result.pinnedBytes=entries.values.filter{$0.pins>0}.reduce(0){$0+$1.key.byteCount};return result
  }
}
