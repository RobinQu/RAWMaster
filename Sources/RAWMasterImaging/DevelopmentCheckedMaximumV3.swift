import Foundation
import CoreImage
import Darwin

/// Validation transport only; never part of a recipe, pixel key or RGB operator version.
/// All calls run synchronously on their existing native worker.
enum DevelopmentCheckedMaximumV3 {
  static let transportVersion = "checked-maximum-integral1024-clear-after-join-fractional-whole-v3"
  static let tileSide: CGFloat = 1024

  struct ScalarRecordBudget {
    static let limit=1024
    enum Reservation { case tile,overflow,discard }
    private var tiles=0,overflow=false
    mutating func reserve() -> Reservation {
      if tiles < Self.limit { tiles += 1;return .tile }
      if !overflow { overflow=true;return .overflow }
      return .discard
    }
  }

  /// Opt-in QA scalars only. The process-wide bound covers all validations, not each tile loop.
  /// This sink owns no image/task/recipe/path and never holds its lock across native work.
  private final class ScalarSink: @unchecked Sendable {
    static let shared=ScalarSink()
    private let lock=NSLock()
    private var budget=ScalarRecordBudget()
    func reserveTile(validationID:String,index:Int,count:Int) -> Bool {
      lock.lock();defer { lock.unlock() }
      switch budget.reserve() {
      case .tile:return true
      case .overflow:
        write(["kind":"overflow","tileRecordLimit":ScalarRecordBudget.limit,
          "validationID":validationID,"tileIndex":index,"tileCount":count,"closedPhase":"record-limit"])
        return false
      case .discard:return false
      }
    }
    func emit(_ fields:[String:Any]) {
      lock.lock();defer { lock.unlock() };write(fields)
    }
    private func write(_ fields:[String:Any]) {
      var fields=fields;fields["tag"]="rawmaster-maximum-qa-scalars"
      guard var data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) else { return }
      data.append(0x0a);try? FileHandle.standardError.write(contentsOf:data)
    }
  }
  private final class ScalarValidation {
    private struct Tile {
      let index,count:Int
      let started:UInt64
      var phase="pre-write-check",writerStarted:UInt64?,writerElapsed:UInt64?
      var clearStarted:UInt64?,clearElapsed:UInt64?,beforeClear:UInt64?,afterClear:UInt64?
    }
    let id=UUID().uuidString
    private var tile:Tile?
    static func enabled() -> ScalarValidation? {
      ProcessInfo.processInfo.environment["RAWMASTER_MAXIMUM_QA_SCALARS"] == "1" ? ScalarValidation():nil
    }
    private static func footprint() -> UInt64? {
      var info=task_vm_info_data_t()
      var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
      let status=withUnsafeMutablePointer(to:&info) { pointer in
        pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
          task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
        }
      }
      return status == KERN_SUCCESS ? UInt64(info.phys_footprint):nil
    }
    func beginTile(index:Int,count:Int) {
      tile=ScalarSink.shared.reserveTile(validationID:id,index:index,count:count) ? Tile(index:index,count:count,started:DispatchTime.now().uptimeNanoseconds):nil
    }
    func phase(_ phase:String) { tile?.phase=phase }
    func beginWriter() { tile?.writerStarted=DispatchTime.now().uptimeNanoseconds }
    func endWriter() {
      if let start=tile?.writerStarted { tile?.writerElapsed=DispatchTime.now().uptimeNanoseconds-start }
    }
    func beforeClear() {
      guard tile != nil else { return }
      tile?.beforeClear=Self.footprint();tile?.clearStarted=DispatchTime.now().uptimeNanoseconds
    }
    func afterClear() {
      guard let start=tile?.clearStarted else { return }
      tile?.clearElapsed=DispatchTime.now().uptimeNanoseconds-start;tile?.afterClear=Self.footprint()
    }
    func finishTile(success:Bool) {
      guard let tile else { return };self.tile=nil
      func scalar(_ value:UInt64?) -> Any { value.map { $0 as Any } ?? NSNull() }
      ScalarSink.shared.emit(["kind":"tile","validationID":id,"tileIndex":tile.index,"tileCount":tile.count,
        "success":success,"closedPhase":success ? "success":tile.phase+"-error",
        "tileStartedUptimeNanoseconds":tile.started,"closedUptimeNanoseconds":DispatchTime.now().uptimeNanoseconds,
        "writerElapsedNanoseconds":scalar(tile.writerElapsed),"clearElapsedNanoseconds":scalar(tile.clearElapsed),
        "beforeClearPhysFootprintBytes":scalar(tile.beforeClear),"afterClearPhysFootprintBytes":scalar(tile.afterClear),
        "measurementScope":"joined-tile-boundaries-not-continuous-task-peak"])
    }
  }

  /// O(1) iterator. The original continuous domain is intersected with absolute grid cells;
  /// neither its fractional boundary nor the upstream image is rounded, cropped or translated.
  struct Partition: Sequence, IteratorProtocol {
    private let domain: CGRect
    private let firstX, endX, endY: Int64
    private var x, y: Int64
    let count: Int
    init(domain: CGRect) throws {
      guard !domain.isNull,!domain.isInfinite,!domain.isEmpty,
        domain.minX.isFinite,domain.minY.isFinite,domain.maxX.isFinite,domain.maxY.isFinite,domain.size.width > 0,domain.size.height > 0 else { throw DevelopmentV3Error.invalidGraph }
      func index(_ value: CGFloat, upper: Bool) throws -> Int64 {
        let n = upper ? ceil(value/DevelopmentCheckedMaximumV3.tileSide):floor(value/DevelopmentCheckedMaximumV3.tileSide)
        guard n > CGFloat(Int64.min),n < CGFloat(Int64.max) else { throw DevelopmentV3Error.invalidGraph }
        return Int64(n)
      }
      let sx = try index(domain.minX,upper:false),sy = try index(domain.minY,upper:false)
      let ex = try index(domain.maxX,upper:true),ey = try index(domain.maxY,upper:true)
      let (nx,ox) = ex.subtractingReportingOverflow(sx)
      let (ny,oy) = ey.subtractingReportingOverflow(sy)
      let (total,ot) = nx.multipliedReportingOverflow(by:ny)
      guard !ox,!oy,!ot,nx > 0,ny > 0,total <= Int64(Int.max) else { throw DevelopmentV3Error.invalidGraph }
      self.domain=domain;firstX=sx;endX=ex;endY=ey;x=sx;y=sy;count=Int(total)
    }
    mutating func next() -> CGRect? {
      guard y < endY else { return nil }
      let cell = CGRect(x:CGFloat(x)*DevelopmentCheckedMaximumV3.tileSide,y:CGFloat(y)*DevelopmentCheckedMaximumV3.tileSide,width:DevelopmentCheckedMaximumV3.tileSide,height:DevelopmentCheckedMaximumV3.tileSide)
      let result = domain.intersection(cell)
      x += 1
      if x == endX { x=firstX;y += 1 }
      return result
    }
  }

  enum WholeMapping { case automaticExtent, originZero }

  static func isIntegralDomain(_ domain: CGRect) -> Bool {
    !domain.isNull && !domain.isInfinite && !domain.isEmpty && domain.size.width > 0 && domain.size.height > 0 &&
      domain.minX.isFinite && domain.minY.isFinite && domain.maxX.isFinite && domain.maxY.isFinite &&
      domain.minX == floor(domain.minX) && domain.minY == floor(domain.minY) &&
      domain.maxX == floor(domain.maxX) && domain.maxY == floor(domain.maxY)
  }

  static func maximum(_ graph: CIImage, domain: CGRect, context: CIContext,
                      wholeMapping: WholeMapping = .automaticExtent,
                      checkCancellation: (() throws -> Void)? = nil) throws -> SIMD4<Float> {
    _ = try Partition(domain:domain) // same finite/domain/overflow rejection before either path
    var scalars:ScalarValidation?
    func writeAndJoin(_ rect: CGRect,_ pointer: UnsafeMutableRawPointer,_ mapping: WholeMapping) throws {
      try autoreleasepool {
        let reduced=graph.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:rect)])
        let destination=CIRenderDestination(bitmapData:pointer,width:1,height:1,bytesPerRow:16,format:.RGBAf)
        destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
        destination.isFlipped=true;destination.isClamped=false;destination.isDithered=false
        let task: CIRenderTask
        scalars?.phase("start")
        switch mapping {
        case .automaticExtent: task=try context.startTask(toRender:reduced,to:destination)
        case .originZero: task=try context.startTask(toRender:reduced,from:.init(x:0,y:0,width:1,height:1),to:destination,at:.zero)
        }
        scalars?.phase("wait")
        do { _ = try task.waitUntilCompleted() }
        catch {
          let original=error
          // Keep the borrowed pointer and task alive through completion, including error unwind.
          _ = try? task.waitUntilCompleted()
          scalars?.phase("wait-after-error-rejoin")
          throw original
        }
        scalars?.phase("post-join-check")
      }
    }
    guard isIntegralDomain(domain) else {
      // Preserve each caller's historical WHOLE mapping. Fractional streaming is unqualified.
      return try checkedJoinedPixel(checkCancellation:checkCancellation) { try writeAndJoin(domain,$0,wholeMapping) }
    }
    scalars=ScalarValidation.enabled()
    return try streamedMaximum(domain:domain,checkCancellation:checkCancellation,
                               cleanupAfterTile:{ context.clearCaches() },scalars:scalars) { rect,pointer in
      // Integral streaming retains the S1 mapping, independently of the fractional caller path.
      try writeAndJoin(rect,pointer,.automaticExtent)
    }
  }

  private static func checkedJoinedPixel(checkCancellation: (() throws -> Void)?,
                                         writeAndJoin: (UnsafeMutableRawPointer) throws -> Void) throws -> SIMD4<Float> {
    try Task.checkCancellation();try checkCancellation?()
    var pixel=SIMD4<Float>(repeating:.nan)
    try withUnsafeMutableBytes(of:&pixel) { bytes in try writeAndJoin(bytes.baseAddress!) }
    // Revocation cannot release a submitted pointer early; the writer has actually joined.
    try Task.checkCancellation();try checkCancellation?()
    guard pixel.x.isFinite,pixel.y.isFinite,pixel.z.isFinite,pixel.w.isFinite else { throw DevelopmentError.invalidEncoding }
    return pixel
  }

  /// Synchronous task seam: writeAndJoin may return only after native ownership has joined.
  /// A poison result can never count as a successful maximum, even for alpha0 graphs.
  /// Cleanup runs after the writer's scopes unwind, before post-join validation or the next tile.
  /// It also runs after a start failure (no task submitted) or an error whose task was joined.
  static func maximum(domain: CGRect, checkCancellation: (() throws -> Void)? = nil,
                      cleanupAfterTile: (() -> Void)? = nil,
                      writeAndJoin: (CGRect,UnsafeMutableRawPointer) throws -> Void) throws -> SIMD4<Float> {
    try streamedMaximum(domain:domain,checkCancellation:checkCancellation,cleanupAfterTile:cleanupAfterTile,scalars:nil,writeAndJoin:writeAndJoin)
  }
  private static func streamedMaximum(domain: CGRect,checkCancellation: (() throws -> Void)?,
                                      cleanupAfterTile: (() -> Void)?,scalars:ScalarValidation?,
                                      writeAndJoin: (CGRect,UnsafeMutableRawPointer) throws -> Void) throws -> SIMD4<Float> {
    let partition=try Partition(domain:domain)
    var result: SIMD4<Float>?
    for (index,rect) in partition.enumerated() {
      guard !rect.isEmpty,rect.width > 0,rect.height > 0,rect.width <= tileSide,rect.height <= tileSide else { throw DevelopmentV3Error.invalidGraph }
      scalars?.beginTile(index:index,count:partition.count)
      let pixel:SIMD4<Float>
      do {
        pixel=try checkedJoinedPixel(checkCancellation:checkCancellation) { pointer in
          // The production writer's autoreleasepool and wait/error-join have exited first.
          defer {
            scalars?.beforeClear();cleanupAfterTile?();scalars?.afterClear()
          }
          scalars?.beginWriter()
          defer { scalars?.endWriter() }
          try writeAndJoin(rect,pointer)
        }
        scalars?.finishTile(success:true)
      } catch {
        scalars?.finishTile(success:false);throw error
      }
      if let previous=result {
        result = .init(max(previous.x,pixel.x),max(previous.y,pixel.y),max(previous.z,pixel.z),max(previous.w,pixel.w))
      } else { result=pixel } // zero would be wrong for an all-negative finite field
    }
    guard let result else { throw DevelopmentV3Error.invalidGraph };return result
  }
}
