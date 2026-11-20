import Foundation
import CoreImage
import RAWMasterCore

enum RawBaseCacheError: Error { case unavailable, ineligible, capacity, allocationProtocol, inFlight(Error) }

enum NativeWBRequest: Hashable {
  case asShot
  case temperatureTint(UInt32, UInt32)
}
struct RawBaseResidentRequestKey: Hashable {
  let sourceKey: String
  let captureStamp: PreviewFileStamp
  let decoderIdentity: String
  let nativeContract: String
  let exposureBits: UInt32
  let whiteBalance: NativeWBRequest
  let nativeParameterFingerprint: String?
  init(sourceKey: String, captureStamp: PreviewFileStamp, decoderIdentity: String, nativeContract: String, recipe: DevelopmentRecipe) {
    self.sourceKey = sourceKey; self.captureStamp = captureStamp
    self.decoderIdentity = decoderIdentity; self.nativeContract = nativeContract
    exposureBits = Float(recipe.exposureEV).bitPattern; nativeParameterFingerprint = nil
    switch recipe.whiteBalance {
    case .asShot: whiteBalance = .asShot
    case let .temperatureTint(t, v): whiteBalance = .temperatureTint(Float(t).bitPattern, Float(v).bitPattern)
    }
  }
  init(sourceKey: String, captureStamp: PreviewFileStamp, decoderIdentity: String, nativeContract: String,
       exposureBits: UInt32, whiteBalance: NativeWBRequest, nativeParameterFingerprint: String) {
    self.sourceKey = sourceKey; self.captureStamp = captureStamp; self.decoderIdentity = decoderIdentity
    self.nativeContract = nativeContract; self.exposureBits = exposureBits; self.whiteBalance = whiteBalance
    self.nativeParameterFingerprint = nativeParameterFingerprint
  }
}
struct RawBaseDescriptor: Hashable {
  let sourceKey: String, decoder: String, nativeContract: String
  let exposureBits: UInt32, whiteBalanceMode: String, temperatureBits: UInt32, tintBits: UInt32
  let orientation: UInt32, width: Int, height: Int
  let nativeParameterFingerprint: String?
  init(sourceKey: String, decoder: String, nativeContract: String, exposureBits: UInt32, whiteBalanceMode: String,
       temperatureBits: UInt32, tintBits: UInt32, orientation: UInt32, width: Int, height: Int, nativeParameterFingerprint: String? = nil) {
    self.sourceKey = sourceKey; self.decoder = decoder; self.nativeContract = nativeContract; self.exposureBits = exposureBits
    self.whiteBalanceMode = whiteBalanceMode; self.temperatureBits = temperatureBits; self.tintBits = tintBits
    self.orientation = orientation; self.width = width; self.height = height; self.nativeParameterFingerprint = nativeParameterFingerprint
  }
}
private enum RawBasePoolIdentity: Hashable {
  case legacyRaw(RawBaseDescriptor)
  case nativePointwise(PreviewNativePointwiseBaseDescriptorV1)
  var sourceKey: String { switch self { case .legacyRaw(let d):return d.sourceKey;case .nativePointwise(let d):return d.sourceKey } }
  var width: Int { switch self { case .legacyRaw(let d):return d.width;case .nativePointwise(let d):return d.width } }
  var height: Int { switch self { case .legacyRaw(let d):return d.height;case .nativePointwise(let d):return d.height } }
}
struct RawBaseStatisticsSnapshot: Sendable {
  var residentBytes = 0, reservedBytes = 0, buildingBytes = 0, pinnedBytes = 0, retiredBytes = 0
  var version: UInt64 = 0
  var hits: UInt64 = 0, fills: UInt64 = 0, misses: UInt64 = 0, evictions: UInt64 = 0
}
/// Sole production instance belongs to DevelopmentPreviewService.shared; tests own isolated pools.
/// The queue owns ALL storage/pin mutations and color/CPU access, not merely dictionary operations.
final class PreviewRawBasePool: @unchecked Sendable {
  private final class Entry {
    var owner: RawBaseStorage?
    let identity: RawBasePoolIdentity
    var pins = 0, retired = false, use: UInt64 = 0
    var verifiedRequest: RawBaseResidentRequestKey?
    init(_ owner: RawBaseStorage, _ identity: RawBasePoolIdentity) { self.owner = owner; self.identity = identity }
  }
  private let queue = DispatchQueue(label:"RAWMaster.preview.raw-base",qos:.userInitiated)
  private let byteBudget: Int, maximumEntries: Int
  let nativeFillMode: RawBaseFillMode
  private let observation: ((String) throws -> Void)?
  private var entries: [RawBasePoolIdentity:Entry] = [:]
  private var tick: UInt64 = 0
  private var snapshotVersion: UInt64 = 0
  private var counters = RawBaseStatisticsSnapshot()
  init(byteBudget: Int, maximumEntries: Int = 2, nativeFillMode: RawBaseFillMode = .whole, observation: ((String) throws -> Void)? = nil) {
    self.observation = observation; self.nativeFillMode = nativeFillMode
    self.byteBudget = max(0,min(1_073_741_824,byteBudget)); self.maximumEntries = max(1,min(2,maximumEntries))
  }
  func withWorker<T>(_ body: () throws -> T) rethrows -> T { try queue.sync(execute:body) }
  func checkpoint(_ label: String) throws { assertWorker(); try observation?(label) }
  private func assertWorker() { dispatchPrecondition(condition:.onQueue(queue)) }
  var statistics: RawBaseStatisticsSnapshot {
    assertWorker(); snapshotVersion &+= 1; var result = counters; result.version = snapshotVersion
    for entry in entries.values {
      let bytes = entry.owner?.allocationBytes ?? 0
      if entry.retired { result.retiredBytes += bytes } else { result.residentBytes += bytes }
      if entry.pins > 0 { result.pinnedBytes += bytes }
    }
    return result
  }
  private var chargedBytes: Int { entries.values.reduce(counters.reservedBytes+counters.buildingBytes){$0+($1.owner?.allocationBytes ?? 0)} }
  /// Only an exact request previously verified against this entry's FULL actual descriptor may pin.
  /// A miss has no side effects/counters; the existing descriptor path records the actual miss.
  func acquireResident(_ request: RawBaseResidentRequestKey) -> RawBasePin? {
    assertWorker()
    guard let entry = entries.values.first(where: { !$0.retired && $0.owner != nil && $0.verifiedRequest == request }),
      let owner = entry.owner else { return nil }
    tick &+= 1; entry.use = tick; entry.pins += 1; counters.hits &+= 1
    return pin(owner, entry.identity)
  }
  func acquire(_ descriptor: RawBaseDescriptor, verifiedRequest: RawBaseResidentRequestKey? = nil, fill: (RawBaseStorage) throws -> Void) throws -> RawBasePin {
    assertWorker()
    if let request = verifiedRequest {
      guard request.sourceKey == descriptor.sourceKey, request.decoderIdentity == descriptor.decoder,
        request.nativeContract == descriptor.nativeContract, request.exposureBits == descriptor.exposureBits else { throw RawBaseCacheError.allocationProtocol }
    }
    return try acquireIdentity(.legacyRaw(descriptor),verifiedRequest:verifiedRequest,fill:fill)
  }
  /// No old finite summary or legacy descriptor can authorize a native-pointwise owner.
  /// The immutable request facts have been verified against the fresh fill's actual defaults.
  func acquirePointwiseResident(_ descriptor: PreviewNativePointwiseBaseDescriptorV1) -> RawBasePin? {
    assertWorker();let key=RawBasePoolIdentity.nativePointwise(descriptor)
    guard let entry=entries[key],!entry.retired,let owner=entry.owner,
      owner.pointwiseInputCertificate?.owner==owner.ownerIncarnation else { return nil }
    tick &+= 1;entry.use=tick;entry.pins+=1;counters.hits &+= 1
    return pin(owner,key)
  }
  func acquirePointwise(_ descriptor: PreviewNativePointwiseBaseDescriptorV1,
                        publicationGate: ((() -> RawBasePin) throws -> RawBasePin)? = nil,
                        fill: (RawBaseStorage) throws -> Void) throws -> RawBasePin {
    let authority=try descriptor.fingerprint()
    return try acquireIdentity(.nativePointwise(descriptor),verifiedRequest:nil,publicationGate:publicationGate) { storage in
      try fill(storage)
      guard let certificate=storage.pointwiseInputCertificate,certificate.authority==authority,
        certificate.owner==storage.ownerIncarnation else { throw RawBaseCacheError.allocationProtocol }
    }
  }
  private func acquireIdentity(_ identity: RawBasePoolIdentity,verifiedRequest: RawBaseResidentRequestKey?,
                               publicationGate: ((() -> RawBasePin) throws -> RawBasePin)? = nil,
                               fill: (RawBaseStorage) throws -> Void) throws -> RawBasePin {
    assertWorker();tick &+= 1
    if let entry = entries[identity], !entry.retired, let owner = entry.owner {
      entry.pins += 1; entry.use = tick; entry.verifiedRequest = verifiedRequest; counters.hits &+= 1
      return pin(owner,identity)
    }
    if let old=entries[identity],old.retired,old.pins>0 { throw RawBaseCacheError.capacity }
    counters.misses &+= 1
    let reservation = try RawBaseStorage.layout(width:identity.width,height:identity.height).bytes
    guard reservation <= byteBudget else { throw RawBaseCacheError.capacity }
    while chargedBytes + reservation > byteBudget || entries.count >= maximumEntries {
      guard let victim = entries.filter({$0.value.pins == 0}).min(by:{$0.value.use < $1.value.use}) else { throw RawBaseCacheError.capacity }
      remove(victim.key)
    }
    counters.reservedBytes += reservation
    var storage: RawBaseStorage?
    defer { counters.reservedBytes = 0; counters.buildingBytes = 0 }
    do {
      storage = try RawBaseStorage(width:identity.width,height:identity.height)
      let actual = storage!.allocationBytes
      counters.reservedBytes -= reservation; counters.buildingBytes += actual
      // Oversized allocation is a protocol failure, charged until the owner actually releases.
      guard actual <= reservation, chargedBytes <= byteBudget else { throw RawBaseCacheError.allocationProtocol }
      do { try autoreleasepool { try fill(storage!) } }
      catch { throw RawBaseCacheError.inFlight(error) }
      let install: () -> RawBasePin = {
        let entry = Entry(storage!,identity); entry.pins = 1; entry.use = self.tick; entry.verifiedRequest = verifiedRequest
        self.entries[identity] = entry; self.counters.buildingBytes -= actual; self.counters.fills &+= 1
        let result = self.pin(storage!,identity); storage = nil; return result
      }
      if let publicationGate { return try publicationGate(install) }
      return install()
    } catch { storage = nil; throw error }
  }
  private func pin(_ owner: RawBaseStorage, _ key: RawBasePoolIdentity) -> RawBasePin {
    RawBasePin(owner:owner) { [unowned self] in
      self.assertWorker()
      guard let entry = self.entries[key], entry.owner === owner, entry.pins > 0 else { return }
      entry.pins -= 1
      if entry.retired && entry.pins == 0 { self.remove(key) }
    }
  }
  private func remove(_ key: RawBasePoolIdentity) {
    assertWorker(); guard let entry = entries[key], entry.pins == 0 else { return }
    entry.owner = nil; entries.removeValue(forKey:key); counters.evictions &+= 1
  }
  func retire(sourceKey: String) {
    assertWorker()
    for key in Array(entries.keys) where key.sourceKey == sourceKey {
      entries[key]?.retired = true
      entries[key]?.owner?.invalidatePointwiseCertificate()
      if entries[key]?.pins == 0 { remove(key) }
    }
  }
  func evictUnpinned(except descriptor: RawBaseDescriptor? = nil) {
    assertWorker()
    for key in Array(entries.keys) where (descriptor.map { key != .legacyRaw($0) } ?? true) && entries[key]?.pins == 0 { remove(key) }
  }
  func drain() throws -> RawBaseStatisticsSnapshot {
    assertWorker()
    for entry in entries.values { entry.retired = true;entry.owner?.invalidatePointwiseCertificate() }
    evictUnpinned()
    guard entries.isEmpty else { throw DevelopmentPreviewError.capacityExceeded }
    return statistics
  }
  /// Actor sends copied commands only; queue executes after the actual current native pipeline.
  func maintain(retiring: Set<String>, clear: Bool) async -> RawBaseStatisticsSnapshot {
    await withCheckedContinuation { continuation in
      queue.async {
        for key in retiring { self.retire(sourceKey:key) }
        if clear { self.evictUnpinned() }
        continuation.resume(returning:self.statistics)
      }
    }
  }
}
final class RawBasePin {
  private var owner: RawBaseStorage?
  private var view: CIImage?
  private var release: (() -> Void)?
  init(owner: RawBaseStorage, release: @escaping () -> Void) { self.owner = owner; view = owner.image(); self.release = release }
  var ownerIncarnation: UUID? { owner?.ownerIncarnation }
  var pointwiseInputCertificate: PreviewNativePointwiseCertificateV1.Input? { owner?.pointwiseInputCertificate }
  var pointwiseSamplerCertificate: PreviewNativePointwiseCertificateV1.Sampler? {
    get { owner?.pointwiseSamplerCertificate }
    set { owner?.pointwiseSamplerCertificate = newValue }
  }
  var image: CIImage { get throws { guard let view, owner != nil else { throw DevelopmentPreviewError.closed }; return view } }
  func releaseAfterJoinedPipeline() {
    // Retaining this released object must retain neither view nor storage.
    view = nil; owner = nil; let callback = release; release = nil; callback?()
  }
}
