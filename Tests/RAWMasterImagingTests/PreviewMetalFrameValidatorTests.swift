import Metal
import XCTest
@testable import RAWMasterImaging

final class PreviewMetalFrameValidatorTests: XCTestCase {
  func testAllPixelsTailsTransparentOutputAndCancellation() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:229,height:13,mipmapped:false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:texture.width,height:texture.height,mipmapped:false)
    outputDescriptor.storageMode = .shared
    outputDescriptor.usage = .shaderWrite
    let display=try XCTUnwrap(device.makeTexture(descriptor:outputDescriptor))
    let ledger = PreviewPresentationLedger(cpuBudget:1<<20,gpuBudget:1<<20)
    let scope = PreviewPresentationScope(ledgerForTesting:ledger)
    defer { scope.closeAndRetire() }
    var pixels = Array(repeating:SIMD4<Float>(-0.4,3,0.2,1),count:texture.width*texture.height)
    func checked(_ requireVisible: Bool = true, display:MTLTexture?=nil, rendering: () throws -> Int = { 7 }) throws -> Int {
      pixels.withUnsafeBytes { bytes in
        texture.replace(region:.init(origin:.init(x:0,y:0,z:0),size:.init(width:texture.width,height:texture.height,depth:1)),
          mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:texture.width*16)
      }
      defer { XCTAssertEqual(ledger.statistics.chargedGPUBytes,0) }
      let allocation = PreviewMetalFrameValidator.allocation(width:texture.width,height:texture.height)
      return try PreviewMetalFrameValidator.checked(texture,ticket:scope.reserveSharedOperation(bytes:[allocation])[0],
        requireVisible:requireVisible,display:display,check:{},rendering:rendering)
    }
    XCTAssertEqual(try checked(),7)
    XCTAssertEqual(try checked(display:display),7)
    for (index, bad) in [(0,SIMD4<Float>(.nan,0,0,0)),(1222,.init(0,.infinity,0,1)),
                         (2048,.init(0,0,0,-0.00001)),(pixels.count-1,.init(0,0,0,1.00001))] {
      let old = pixels[index]
      pixels[index] = bad
      XCTAssertThrowsError(try checked())
      XCTAssertThrowsError(try checked(display:display))
      pixels[index] = old
    }
    pixels = Array(repeating:.zero,count:pixels.count)
    XCTAssertThrowsError(try checked())
    XCTAssertThrowsError(try checked(display:display))
    XCTAssertEqual(try checked(false),7)
    pixels[pixels.count-1].w = 0.3
    XCTAssertEqual(try checked(),7)
    XCTAssertEqual(try checked(display:display),7)
    XCTAssertThrowsError(try checked(rendering:{throw CancellationError()}))
  }
}
