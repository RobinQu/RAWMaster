import AppKit
import CoreImage
import Metal
import XCTest
@testable import RAWMasterImaging

final class PreviewSharedSurfaceScopeTests: XCTestCase {
  func testScopeRetirementDoesNotCloseOtherScopesAndRetainedTicketsStayCharged() throws {
    let ledger = PreviewPresentationLedger(cpuBudget:100,gpuBudget:80)
    let a = PreviewPresentationScope(ledgerForTesting:ledger), b = PreviewPresentationScope(ledgerForTesting:ledger)
    let first = try a.reserveSharedSurface(bytes:40)
    try first.registerActualAllocation(bytes:40)
    a.closeAndRetire(); a.closeAndRetire()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,40)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes,40)
    XCTAssertFalse(ledger.statistics.admissionClosed)
    XCTAssertThrowsError(try first.requireOpenAdmission())
    XCTAssertThrowsError(try a.reserveCPUFallback(bytes:1))
    let second = try b.reserveSharedSurface(bytes:40)
    try second.registerActualAllocation(bytes:40)
    try second.requireOpenAdmission()
    XCTAssertThrowsError(try b.reserveSharedSurface(bytes:1))
    let cpu = try b.reserveCPUFallback(bytes:20)
    try cpu.registerActualAllocation(bytes:20)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,100)
    XCTAssertThrowsError(try b.reserveCPUFallback(bytes:1))
    first.releaseAfterStorageReleased()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,60)
    _ = ledger.closeAdmissionAndRetire()
    XCTAssertThrowsError(try second.requireOpenAdmission())
    second.releaseAfterStorageReleased(); cpu.releaseAfterStorageReleased()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
  func testScopeCloseDuringAllocationChargesUntilActualRelease() throws {
    let ledger = PreviewPresentationLedger(cpuBudget:100,gpuBudget:100)
    let scope = PreviewPresentationScope(ledgerForTesting:ledger)
    let ticket = try scope.reserveSharedSurface(bytes:60)
    scope.closeAndRetire()
    XCTAssertThrowsError(try ticket.registerActualAllocation(bytes:60)) { XCTAssertEqual($0 as? PreviewPresentationError,.closed) }
    XCTAssertEqual(ledger.statistics.retiredGPUBytes,60)
    ticket.releaseAfterStorageReleased()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
    let next = PreviewPresentationScope(ledgerForTesting:ledger)
    let accepted = try next.reserveCPUFallback(bytes:100)
    try accepted.registerActualAllocation(bytes:100)
    accepted.releaseAfterStorageReleased()
  }
  func testFractionalExtentRefusedBeforeSubmissionWithoutCanvasNormalization() throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_P4_A0_GPU_TINY"] == "1" else {
      throw XCTSkip("Root must authorize the old-CI canvas observation")
    }
    let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512])
    defer { context.clearCaches() }
    // CICrop may integralize a requested fractional crop. Start with a real
    // integer extent, then use an affine transform to exercise the actual
    // materializer boundary rather than assuming the requested crop survived.
    let base = CIImage(color:CIColor(red:0.2,green:0.5,blue:0.8,alpha:0.5))
      .cropped(to:CGRect(x:0,y:0,width:5,height:3))
    for transform in [CGAffineTransform(a:1.05,b:0,c:0,d:7.0/6.0,tx:0,ty:0),
                      CGAffineTransform(a:1.05,b:0,c:0,d:7.0/6.0,tx:0.25,ty:-0.5)] {
      let image = base.transformed(by:transform), actualExtent = image.extent
      guard actualExtent != actualExtent.integral else {
        throw XCTSkip("This CI implementation integralized the noninteger affine extent \(actualExtent); fractional refusal remains unverified")
      }
      XCTAssertNotEqual(actualExtent,actualExtent.integral)
      try DevelopmentColorEngineV2.validateFinite(image,context:context)
      let graph = DevelopedV3Graph(image:image,sourceDepth:32,sourceSize:actualExtent.size,canonicalSize:actualExtent.size,graphDescriptor:"tiny-fractional-no-normalization")
      let old = try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:2400)
      let cg = try XCTUnwrap(old.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      // Observe CGImage's actual rounding rather than guessing ceil/integral.
      XCTAssertEqual(old.outputSize,CGSize(width:cg.width,height:cg.height))
      XCTAssertGreaterThan(cg.bytesPerRow,0); XCTAssertEqual(cg.bitsPerPixel,32)
      print("A0 fractional fixture actualExtent=\(actualExtent) oldCanvas=\(cg.width)x\(cg.height) rowBytes=\(cg.bytesPerRow) bitmapInfo=\(cg.bitmapInfo.rawValue) alphaInfo=\(cg.alphaInfo.rawValue)")
      let ledger = PreviewPresentationLedger(), scope = PreviewPresentationScope(ledgerForTesting:ledger)
      var submitted = 0
      XCTAssertThrowsError(try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:2400,presentation:scope,observation:{ _ in submitted += 1 })) {
        XCTAssertEqual($0 as? PreviewPresentationError,.unsupported)
      }
      XCTAssertEqual(submitted,0); XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
      XCTAssertEqual(graph.image.extent,actualExtent)
    }
  }
  func testOptInIntegerMaterializerKeepsCanvasAndScopeCloseJoinsWithoutGlobalShutdown() throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_P4_A0_GPU_TINY"] == "1",
      let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Root-authorized tiny GPU required") }
    let ledger = PreviewPresentationLedger(), scope = PreviewPresentationScope(ledgerForTesting:ledger)
    let context = CIContext(mtlDevice:device,options:[.cacheIntermediates:false,
      .workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512])
    defer { context.clearCaches() }
    let image = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6,alpha:0.5)).cropped(to:CGRect(x:0,y:0,width:5,height:3))
    try DevelopmentColorEngineV2.validateFinite(image,context:context)
    let graph = DevelopedV3Graph(image:image,sourceDepth:32,sourceSize:image.extent.size,canonicalSize:image.extent.size,graphDescriptor:"tiny-integer")
    let cpu = try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:2400)
    try autoreleasepool {
      let a0 = try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:2400,presentation:scope,device:device)
      XCTAssertEqual(a0.outputSize,cpu.outputSize)
      let a = NSBitmapImageRep(cgImage:try XCTUnwrap(cpu.image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
      let b = NSBitmapImageRep(cgImage:try XCTUnwrap(a0.image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
      XCTAssertEqual(a.pixelsWide,b.pixelsWide); XCTAssertEqual(a.pixelsHigh,b.pixelsHigh)
      for y in 0..<3 { for x in 0..<5 {
        let ca = try XCTUnwrap(a.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
        let cb = try XCTUnwrap(b.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
        for (v,w) in zip([ca.redComponent,ca.greenComponent,ca.blueComponent,ca.alphaComponent],
                         [cb.redComponent,cb.greenComponent,cb.blueComponent,cb.alphaComponent]) {
          XCTAssertLessThanOrEqual(abs(v-w),2.0/255.0)
        }
      } }
      scope.closeAndRetire()
      XCTAssertGreaterThan(ledger.statistics.retiredCPUBytes,0)
      XCTAssertNotNil(a0.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
    let second = PreviewPresentationScope(ledgerForTesting:ledger)
    var joined = 0
    XCTAssertThrowsError(try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:2400,presentation:second,device:device,observation:{ phase in
      if phase == "display-gpu-submitted" { second.closeAndRetire() }
      if phase == "display-gpu-joined" { joined += 1 }
    })) { XCTAssertEqual($0 as? PreviewPresentationError,.closed) }
    XCTAssertEqual(joined,1); XCTAssertFalse(ledger.statistics.admissionClosed)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
  }
}
