import Foundation
import AppKit
import CoreImage
import Darwin

/// Isolated display transport adapted from the actual grain transport.
/// The caller supplies the unchanged, already finite-validated final native graph.
enum PreviewBrillianceBankTransportV1 {
  static let version = "research-brilliance-CG16-whole-viewport-128-v1"
  static let bankCap = 64 * 1024 * 1024
  static let bandHeight = 128

  struct Band {
    let index: Int
    let output, queriedROI, originalBank, bank: CGRect
    let outputTopRow, originalTIFFTopRow, addedTopRows, alignedTIFFTopRow: Int
  }
  struct BandObservation {
    let band: Band
    let samplingGrid: Int
    let factor: CGFloat
    let mappedBankBytes: Int
    let wholeViewportCGBytes: Int
    let producerJoined: Bool
    let providerReleased: Bool
    let startedNS, nativeJoinedNS, displayJoinedNS, providerReleasedNS: UInt64
    func receipt(window: String) -> [String: Any] {
      func rect(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
      return ["window": window, "index": band.index, "globalOutput": rect(band.output),
        "queriedROI": rect(band.queriedROI), "originalNativeBank": rect(band.originalBank), "globalNativeBank": rect(band.bank),
        "physicalOutputTop": band.outputTopRow, "originalTIFFTop": band.originalTIFFTopRow,
        "addedTopRows": band.addedTopRows, "alignedTIFFTop": band.alignedTIFFTopRow, "samplingGrid": samplingGrid,
        "factor": factor, "mappedBankBytes": mappedBankBytes, "wholeViewportCGBytes": wholeViewportCGBytes,
        "nativeCG16ProducerJoined": producerJoined, "providerReleased": providerReleased,
        "startedNS": startedNS, "nativeJoinedNS": nativeJoinedNS, "displayJoinedNS": displayJoinedNS,
        "providerReleasedNS": providerReleasedNS]
    }
  }
  struct Plan {
    let native, output: CGRect
    let factor: CGFloat
    let samplingGrid: Int
    let bands: [Band]
    let maxMappedBankBytes: Int
  }

  /// Hypothesis under test, not a statement about Core Image internals.
  /// This loop is floor(log2(1/factor)) without a logarithm boundary rounding.
  static func samplingGrid(factor: CGFloat) throws -> Int {
    guard factor.isFinite, factor > 0, factor <= 1 else { throw PreviewPresentationError.invalidLayout }
    var grid = 1
    while CGFloat(grid * 2) * factor <= 1 {
      guard grid <= 32_768 else { throw PreviewPresentationError.unsupported }
      grid *= 2
    }
    return grid
  }
  static func plan(_ graph: DevelopedV3Graph, window: PreviewWindows.Window) throws -> Plan {
    let native = graph.image.extent
    guard native.origin == .zero, native == native.integral,
      native.width > 0, native.height > 0, native.width <= 50_000, native.height <= 50_000,
      native.contains(window.ci), window.maximum == 0 || window.maximum == 2400 else { throw PreviewPresentationError.unsupported }
    let factor = window.maximum == 0 ? 1 : min(1, CGFloat(window.maximum) / max(native.width, native.height))
    let affine = factor < 1 ? graph.image.transformed(by: .init(scaleX: factor, y: factor)) : graph.image
    // Keep the original fractional affine extent. Integral bounds are the storage
    // canvas only; no image resampling, crop, or coordinate rebasing is added here.
    let output = window.maximum == 0 ? window.ci : affine.extent.integral
    guard output == output.integral, output.size == window.size, affine.extent.integral.contains(output) else {
      throw PreviewPresentationError.invalidLayout
    }
    return try planBanks(native: native, output: output, factor: factor) {
      affine.regionOfInterest(for: graph.image, in: $0)
    }
  }

  private static func planBanks(native: CGRect, output: CGRect, factor: CGFloat, roiForBand: (CGRect) -> CGRect) throws -> Plan {
    let grid = try samplingGrid(factor: factor)
    var bands = [Band]()
    var maxMappedBankBytes = 0
    for y in stride(from: 0, to: Int(output.height), by: bandHeight) {
      let height = min(bandHeight, Int(output.height) - y)
      let band = CGRect(x: output.minX, y: output.minY + CGFloat(y), width: output.width, height: CGFloat(height))
      let roi = roiForBand(band)
      guard !roi.isNull, !roi.isInfinite, [roi.minX, roi.minY, roi.width, roi.height].allSatisfy(\.isFinite),
        roi.width > 0, roi.height > 0 else { throw PreviewPresentationError.unsupported }
      let grown = roi.integral.insetBy(dx: -1, dy: -1).intersection(native)
      let original = CGRect(x: 0, y: grown.minY, width: native.width, height: grown.height)
      guard !original.isEmpty, original == original.integral, native.contains(original) else { throw PreviewPresentationError.invalidLayout }
      let top = Int(native.maxY - original.maxY)
      // Moving maxY upward reduces TIFF top. Remainder (not grid-remainder)
      // is the number of rows required to round top down to a grid multiple.
      let added = top % grid
      let bank = CGRect(x: 0, y: original.minY, width: native.width, height: original.height + CGFloat(added))
      guard native.contains(bank), Int(native.maxY - bank.maxY) % grid == 0 else { throw PreviewPresentationError.invalidLayout }
      let mappedBytes = try BrillianceBankPages.checkedBytes(width: Int(bank.width), height: Int(bank.height), bits: 16, guarded: true, cap: bankCap)
      maxMappedBankBytes = max(maxMappedBankBytes, mappedBytes)
      bands.append(.init(index: bands.count, output: band, queriedROI: roi, originalBank: original, bank: bank,
        outputTopRow: Int(output.maxY - band.maxY), originalTIFFTopRow: top,
        addedTopRows: added, alignedTIFFTopRow: Int(native.maxY - bank.maxY)))
    }
    return .init(native: native, output: output, factor: factor, samplingGrid: grid, bands: bands, maxMappedBankBytes: maxMappedBankBytes)
  }

  private struct Budget {
    let output, viewport, scratch, total: Int
  }
  private static func budget(_ plan: Plan, outerBytes: Int) throws -> Budget {
    let width = Int(plan.output.width), height = Int(plan.output.height)
    // One possible alias of the largest checked bank in this plan, finite band, and four small RGBA8
    // piece representations. These are capacity reservations, not measured
    // allocations. Final output and actual bank pages receive their own tickets.
    let outputBytes = try BrillianceBankPages.checkedBytes(width: width, height: height, bits: 8, guarded: false,
      cap: 2400 * 2400 * 4 + Int(getpagesize()))
    // Bounded row-aligned capacity; actual CG bytesPerRow must fit, not presumed compact.
    let viewportCapacity = ((width * 4 + 255) / 256 * 256 * height + Int(getpagesize()) - 1) / Int(getpagesize()) * Int(getpagesize())
    let (viewportReserve, reserveOverflow) = viewportCapacity.multipliedReportingOverflow(by: 3)
    guard !reserveOverflow else { throw PreviewPresentationError.invalidLayout }
    let scratchBytes = plan.maxMappedBankBytes + width * bandHeight * (16 + 4 * 4) + viewportReserve
    let total = outerBytes + scratchBytes + plan.maxMappedBankBytes + outputBytes
    guard outerBytes >= 0, total <= 256 * 1024 * 1024 else { throw PreviewPresentationError.displayCapacity }
    return .init(output: outputBytes, viewport: viewportCapacity, scratch: scratchBytes, total: total)
  }

  static func materializeBands(_ graph: DevelopedV3Graph, context: CIContext, window: PreviewWindows.Window,
                              scope: PreviewPresentationScope, outerBytes: Int, check: (String) throws -> Void,
                              phase: (String) -> Void, observe: (BandObservation) -> Void) throws -> (PreviewPixels, Int) {
    try check("bank-\(window.name)-admission"); try scope.requireOpenAdmission()
    let plan = try plan(graph, window: window)
    let width = Int(plan.output.width), height = Int(plan.output.height)
    let budget = try budget(plan, outerBytes: outerBytes)
    let scratch = try scope.reserveCPUFallback(bytes: budget.scratch)
    defer { context.clearCaches(); scratch.releaseAfterStorageReleased() }
    let output = try BrillianceBankPages(width: width, height: height, bits: 8,
      guarded: false, scope: scope, cap: 2400 * 2400 * 4 + Int(getpagesize()), retireOnProviderRelease: true)
    var published = false
    defer { if !published { _ = output.close() } }
    var written = [Bool](repeating: false, count: height)
    for band in plan.bands {
      let label = "bank-\(window.name)-\(band.index)-"
      try check(label + "admission"); try scope.requireOpenAdmission()
      let began = DispatchTime.now().uptimeNanoseconds
      var nativeJoined: UInt64 = 0, displayJoined: UInt64 = 0
      var owner: BrillianceBankPages?
      var primary: Error?
      var mappedBytes = 0
      var wholeCGBytes = 0
      do {
        try autoreleasepool {
          defer { context.clearCaches() }
          let carrier = try BrillianceBankPages(width: Int(band.bank.width), height: Int(band.bank.height),
            bits: 16, guarded: true, scope: scope, cap: bankCap, retireOnProviderRelease: false)
          owner = carrier; mappedBytes = carrier.mappedBytes
          phase(label + "native-CG16")
          try carrier.fill(graph.image, from: band.bank, context: context) {
            try check(label + "native-CG16"); try scope.requireOpenAdmission()
          }
          nativeJoined = DispatchTime.now().uptimeNanoseconds
          phase(label + "whole-viewport")
          let local = try carrier.importedImage()
          let placed = local.transformed(by: .init(translationX: band.bank.minX, y: band.bank.minY))
          let scaled = plan.factor < 1 ? placed.transformed(by: .init(scaleX: plan.factor, y: plan.factor)) : placed
          // Sole candidate: materialize the full final viewport before CG pixel cropping.
          let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: plan.output)
          let viewport = scaled.composited(over: clear).cropped(to: plan.output)
          let normalized = viewport.cropped(to: band.output).transformed(by: .init(translationX: -band.output.minX, y: -band.output.minY))
          // Test the actual imported/FIT graph, including fractional edge coverage.
          try finiteBand(normalized, bounds: CGRect(x: 0, y: 0, width: width, height: Int(band.output.height)), context: context) {
            try check(label + "whole-viewport"); try scope.requireOpenAdmission()
          }
          let piece = try packedViewportBand(viewport, output: plan.output, band: band, capacity: budget.viewport, context: context, actualBytes: &wholeCGBytes)
          displayJoined = DispatchTime.now().uptimeNanoseconds
          try check(label + "whole-viewport")
          let rows = band.outputTopRow ..< band.outputTopRow + Int(band.output.height)
          guard rows.allSatisfy({ !written[$0] }) else { throw PreviewPresentationError.allocationProtocol }
          try output.copy(piece, offset: band.outputTopRow * width * 4)
          for row in rows { written[row] = true }
        }
      } catch { primary = error }
      // All actual CI/CG aliases have left the pool before pages and tickets retire.
      let released = owner?.close() ?? true
      owner = nil
      if !released {
        if let primary {
          throw NSError(domain: "RAWMaster.BrillianceBankCleanup", code: 1,
            userInfo: [NSUnderlyingErrorKey: primary, "cleanupError": PreviewPresentationError.allocationProtocol,
              NSLocalizedDescriptionKey: "Brilliance bank failed and its actual backing could not be released"])
        }
        throw PreviewPresentationError.allocationProtocol
      }
      if let primary { throw primary }
      observe(.init(band: band, samplingGrid: plan.samplingGrid, factor: plan.factor,
        mappedBankBytes: mappedBytes, wholeViewportCGBytes: wholeCGBytes, producerJoined: true, providerReleased: released,
        startedNS: began, nativeJoinedNS: nativeJoined, displayJoinedNS: displayJoined, providerReleasedNS: DispatchTime.now().uptimeNanoseconds))
      try check(label + "released"); try scope.requireOpenAdmission()
    }
    guard written.allSatisfy({ $0 }) else { throw PreviewPresentationError.allocationProtocol }
    let result = try autoreleasepool { () throws -> PreviewPixels in
      try check("bank-\(window.name)-final"); try scope.requireOpenAdmission()
      let cg = try output.makeCGImage()
      let image = NSImage(cgImage: cg, size: plan.output.size)
      try check("bank-\(window.name)-final"); try scope.requireOpenAdmission()
      return .init(image: image, nativeSize: graph.canonicalSize, outputSize: plan.output.size,
        bytes: output.mappedBytes, presentationTicket: output.ticket)
    }
    // NSImage(cgImage:) must actually retain our provider. A copied/early-released
    // image is not evidence of a ticket-backed publication.
    try output.requireLiveProvider()
    try check("bank-\(window.name)-final"); try scope.requireOpenAdmission()
    published = true
    return (result, budget.total)
  }

  private static func finiteBand(_ image: CIImage, bounds: CGRect, context: CIContext, check: () throws -> Void) throws {
    try check()
    let width = Int(bounds.width), height = Int(bounds.height)
    guard width > 0, width <= 2400, height > 0, height <= bandHeight else { throw PreviewPresentationError.invalidLayout }
    var values = [Float](repeating: .nan, count: width * height * 4)
    try values.withUnsafeMutableBytes { bytes in
      let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: width, height: height, bytesPerRow: width * 16, format: .RGBAf)
      destination.colorSpace = DevelopmentColorEngineV3.linearSRGB; destination.alphaMode = .premultiplied
      destination.isFlipped = true; destination.isClamped = false; destination.isDithered = false
      let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
      do { _ = try task.waitUntilCompleted() }
      catch { let original = error; _ = try? task.waitUntilCompleted(); throw original }
    }
    guard values.allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
    try check()
  }
  private static func packedViewportBand(_ image: CIImage, output: CGRect, band: Band, capacity: Int, context: CIContext, actualBytes: inout Int) throws -> Data {
    let width = Int(output.width), height = Int(band.output.height)
    guard image.extent == output,
      let whole = context.createCGImage(image, from: output, format: .RGBA8, colorSpace: PhotoRenderer.sRGB, deferred: false),
      whole.width == width, whole.height == Int(output.height), whole.bitsPerComponent == 8,
      whole.bytesPerRow >= width * 4, whole.bytesPerRow <= capacity / whole.height,
      let cg = whole.cropping(to: CGRect(x: 0, y: band.outputTopRow, width: width, height: height)),
      cg.width == width, cg.height == height,
      let owned = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { throw PreviewPresentationError.invalidLayout }
    actualBytes = whole.bytesPerRow * whole.height
    // Original materializer compact copy, only after full-window CG pixel crop.
    owned.setBlendMode(.copy); owned.interpolationQuality = .none
    owned.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let compact = owned.makeImage() else { throw DevelopmentError.unreadable }
    let bitmap = NSBitmapImageRep(cgImage: compact), result = NSImage(size: CGSize(width: width, height: height))
    result.addRepresentation(bitmap)
    let pixels = PreviewPixels(image: result, nativeSize: output.size, outputSize: CGSize(width: width, height: height),
      bytes: bitmap.bytesPerRow * bitmap.pixelsHigh)
    return try packed(pixels, width: width, height: height)
  }

  private static func packed(_ pixels: PreviewPixels, width: Int, height: Int) throws -> Data {
    guard let cg = pixels.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      cg.width == width, cg.height == height, cg.bitsPerComponent == 8 else { throw PreviewPresentationError.invalidLayout }
    var bytes = Data(repeating: 0xcd, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      guard let copy = CGContext(data: buffer.baseAddress!, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw DevelopmentError.unreadable }
      copy.setBlendMode(.copy); copy.interpolationQuality = .none
      copy.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
  }
}

/// Actual CF provider callbacks retain the backing and balance readers. No weak CF.
private final class BrillianceBankPages {
  let width, height, rowBytes, payload, mappedBytes, bits, guardBytes: Int
  private(set) var ticket: PreviewPresentationReservation?
  private var pages: TIFF16Output.Pages?
  private let retireOnProviderRelease: Bool
  private weak var imageWitness: CIImage?
  private var submitted = false, closed = false, providerCreated = false, failedRetirement = false
  private static let failedLock = NSLock()
  private static var failedOwners = [BrillianceBankPages]()

  static func checkedBytes(width: Int, height: Int, bits: Int, guarded: Bool, cap: Int) throws -> Int {
    guard width > 0, height > 0, width <= 50_000, height <= 50_000, bits == 8 || bits == 16 else { throw PreviewPresentationError.invalidLayout }
    let (row, a) = width.multipliedReportingOverflow(by: bits / 8 * 4)
    let (payload, b) = row.multipliedReportingOverflow(by: height)
    let page = Int(getpagesize())
    let (extra, c) = payload.addingReportingOverflow(guarded ? page * 2 : 0)
    let (padded, d) = extra.addingReportingOverflow(page - 1)
    guard !a, !b, !c, !d, padded > 0 else { throw PreviewPresentationError.invalidLayout }
    let bytes = padded / page * page
    guard bytes <= cap else { throw PreviewPresentationError.displayCapacity }
    return bytes
  }
  init(width: Int, height: Int, bits: Int, guarded: Bool, scope: PreviewPresentationScope, cap: Int, retireOnProviderRelease: Bool) throws {
    self.width = width; self.height = height; self.bits = bits
    self.guardBytes = guarded ? Int(getpagesize()) : 0
    mappedBytes = try Self.checkedBytes(width: width, height: height, bits: bits, guarded: guarded, cap: cap)
    rowBytes = width * (bits / 8) * 4; payload = rowBytes * height
    self.retireOnProviderRelease = retireOnProviderRelease
    do {
      ticket = try scope.reserveCPUFallback(bytes: mappedBytes)
      pages = try TIFF16Output.Pages(mappedBytes)
      try ticket!.registerActualAllocation(bytes: mappedBytes)
      memset(pages!.pointer, 0xcd, mappedBytes)
    } catch { _ = close(); throw error }
  }
  func fill(_ image: CIImage, from rect: CGRect, context: CIContext, check: () throws -> Void) throws {
    try check(); try ticket?.requireOpenAdmission()
    guard bits == 16, let pages, !closed, !providerCreated, image.extent.contains(rect),
      rect.width == CGFloat(width), rect.height == CGFloat(height) else { throw PreviewPresentationError.allocationProtocol }
    pages.borrow(); submitted = true
    defer { submitted = false; pages.finish() }
    let destination = CIRenderDestination(bitmapData: pages.pointer.advanced(by: guardBytes), width: width, height: height, bytesPerRow: rowBytes, format: .RGBA16)
    destination.colorSpace = PhotoRenderer.sRGB; destination.alphaMode = .unpremultiplied
    destination.isFlipped = true; destination.isClamped = true; destination.isDithered = false
    let task = try context.startTask(toRender: image, from: rect, to: destination, at: .zero)
    do { _ = try task.waitUntilCompleted() }
    catch { let original = error; _ = try? task.waitUntilCompleted(); throw original }
    try check(); try guards()
  }
  func copy(_ data: Data, offset: Int) throws {
    guard bits == 8, let pages, !closed, !providerCreated, offset >= 0, offset <= payload,
      data.count <= payload - offset else { throw PreviewPresentationError.allocationProtocol }
    data.withUnsafeBytes { bytes in memcpy(pages.pointer.advanced(by: guardBytes + offset), bytes.baseAddress!, bytes.count) }
  }
  private func guards() throws {
    guard let pages else { throw PreviewPresentationError.allocationProtocol }
    let bytes = pages.pointer.assumingMemoryBound(to: UInt8.self)
    guard (0..<guardBytes).allSatisfy({ bytes[$0] == 0xcd }),
      (guardBytes + payload..<mappedBytes).allSatisfy({ bytes[$0] == 0xcd }) else { throw PreviewPresentationError.allocationProtocol }
  }
  func makeCGImage() throws -> CGImage {
    guard let pages, !closed, !submitted, !providerCreated else { throw PreviewPresentationError.allocationProtocol }
    try guards(); pages.borrow()
    let info = Unmanaged.passRetained(self).toOpaque()
    guard let provider = CGDataProvider(dataInfo: info, data: pages.pointer.advanced(by: guardBytes), size: payload, releaseData: { info, _, _ in
      guard let info else { return }
      let owner = Unmanaged<BrillianceBankPages>.fromOpaque(info)
      owner.takeUnretainedValue().providerDidRelease(); owner.release()
    }) else {
      pages.finish(); Unmanaged<BrillianceBankPages>.fromOpaque(info).release()
      throw PreviewPresentationError.imageCreationFailed
    }
    providerCreated = true
    let bitmapInfo: CGBitmapInfo
    if bits == 16 {
      #if _endian(little)
      bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little)
      #else
      bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Big)
      #endif
    } else {
      bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
    }
    guard let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
      bytesPerRow: rowBytes, space: PhotoRenderer.sRGB, bitmapInfo: bitmapInfo, provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PreviewPresentationError.imageCreationFailed }
    return image
  }
  func importedImage() throws -> CIImage {
    guard bits == 16 else { throw PreviewPresentationError.invalidLayout }
    let cg = try makeCGImage()
    guard cg.width == width, cg.height == height, cg.bitsPerComponent == 16, cg.bitsPerPixel == 64,
      cg.alphaInfo == .last, let icc = cg.colorSpace?.copyICCData(),
      PreviewWindows.sha(icc as Data) == PreviewWindows.icc else { throw PreviewPresentationError.invalidLayout }
    let image = CIImage(cgImage: cg)
    guard image.extent == CGRect(x: 0, y: 0, width: width, height: height) else { throw PreviewPresentationError.invalidLayout }
    imageWitness = image
    return image
  }
  private func providerDidRelease() {
    pages?.finish()
    if retireOnProviderRelease { _ = close() }
  }
  func requireLiveProvider() throws {
    guard providerCreated, !closed, !submitted, let pages, pages.activeReaders > 0,
      let ticket else { throw PreviewPresentationError.allocationProtocol }
    try ticket.requireOpenAdmission()
  }
  @discardableResult func close() -> Bool {
    if closed { return true }
    guard !submitted, imageWitness == nil, (pages?.activeReaders ?? 0) == 0 else { return quarantine() }
    do { try pages?.close() } catch { return quarantine() }
    pages = nil; ticket?.releaseAfterStorageReleased(); ticket = nil; closed = true
    return true
  }
  private func quarantine() -> Bool {
    Self.failedLock.lock(); defer { Self.failedLock.unlock() }
    if !failedRetirement {
      failedRetirement = true; ticket?.recordCleanupFailure(); Self.failedOwners.append(self)
    }
    return false
  }
}

extension PreviewBrillianceBankTransportV1 {
  /// Geometry and byte-ownership checks with CPU fixtures only; creates no CIContext.
  static func cpuSelfTest() throws {
    let native = PreviewWindows.full
    var count = 0
    for window in PreviewWindows.windows {
      let factor: CGFloat = window.maximum == 0 ? 1 : 25 / 99
      let output = window.maximum == 0 ? window.ci : CGRect(origin: .zero, size: window.size)
      // Known inverse ROI for the independent coordinate fixture. Actual graph ROI is recorded at runtime.
      let inverse = CGAffineTransform(scaleX: 1 / factor, y: 1 / factor)
      let plan = try planBanks(native: native, output: output, factor: factor) { $0.applying(inverse) }
      let checked = try budget(plan, outerBytes: PreviewWindows.compactBudget(size: output.size))
      guard plan.samplingGrid == (window.maximum == 0 ? 1 : 2),
        plan.bands.count == (window.maximum == 0 ? 4 : 13),
        plan.bands.first?.output.minY == output.minY, plan.bands.last?.output.maxY == output.maxY,
        checked.total <= 256 * 1024 * 1024, plan.maxMappedBankBytes <= bankCap else {
        throw PreviewPresentationError.invalidLayout
      }
      var rows = [Int]()
      for band in plan.bands {
        let low = band.outputTopRow, high = low + Int(band.output.height)
        guard band.output.minX == output.minX, band.output.maxX == output.maxX,
          low == Int(output.maxY - band.output.maxY), band.alignedTIFFTopRow % plan.samplingGrid == 0,
          band.bank.contains(band.originalBank), band.bank.width == native.width,
          native.contains(band.bank) else { throw PreviewPresentationError.invalidLayout }
        rows.append(contentsOf: low..<high)
      }
      guard rows.sorted() == Array(0..<Int(output.height)) else { throw PreviewPresentationError.invalidLayout }
      count += plan.bands.count
    }
    guard count == 33 else { throw PreviewPresentationError.invalidLayout }
    let scope = PreviewPresentationScope()
    let expected = Data([17,0,0,255, 47,0,0,255, 79,0,0,255, 137,0,0,255])
    try autoreleasepool {
      let pages = try BrillianceBankPages(width: 1, height: 4, bits: 8, guarded: false, scope: scope,
        cap: 1 << 20, retireOnProviderRelease: true)
      try pages.copy(expected, offset: 0)
      let image = try pages.makeCGImage()
      try pages.requireLiveProvider()
      guard let middle = image.cropping(to: CGRect(x: 0, y: 1, width: 1, height: 2)),
        try PreviewWindows.compact(image) == expected,
        try PreviewWindows.compact(middle) == expected.subdata(in: 4..<12) else {
        throw PreviewPresentationError.invalidLayout
      }
    }
    scope.closeAndRetire()
    let final = scope.ledger.statistics
    guard final.chargedCPUBytes == 0, final.chargedGPUBytes == 0, final.cleanupFailures == 0 else {
      throw PreviewPresentationError.allocationProtocol
    }
    print("Brilliance bank CPU fixtures PASS: 33 bands, full top-row coverage, budget, actual CG crop/compact and provider close")
  }
}
