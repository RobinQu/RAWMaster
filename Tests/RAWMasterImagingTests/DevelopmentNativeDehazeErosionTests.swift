import CoreImage
import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentNativeDehazeErosionTests: XCTestCase {
  func testAllWorkgroupsAndPartialRowsMustReportTheirExactPayload() {
    let values: [UInt16] = [0, 0xa100, 0xa010, 0xa020, 0xa002, 0]
    func accepted(_ counts: [UInt16]) -> Bool {
      counts.withUnsafeBufferPointer {
        DevelopmentNativeDehazeErosion.groupsWereWritten($0, offset: 1, width: 17, height: 18)
      }
    }
    XCTAssertTrue(accepted(values))
    for index in 1...4 {
      var omitted = values
      omitted[index] = 0
      XCTAssertFalse(accepted(omitted))
    }
    var missingLastRow = values
    missingLastRow[3] = 0xa010
    missingLastRow[4] = 0xa001
    XCTAssertFalse(accepted(missingLastRow))
    XCTAssertFalse(accepted(Array(values.prefix(4))))
    XCTAssertFalse(accepted([0, 256, 16, 32, 2]))

    let first: [UInt16] = [0xa500, 0xa410, 0xa410, 0xa401]
    let damaged: [UInt16] = [0xa500, 0xa410, 0xa410, 0]
    for missing in 0..<4 {
      let flags = (0..<4).flatMap { $0 == missing ? damaged : first }
      flags.withUnsafeBufferPointer { all in
        let decisions = stride(from: 0, to: all.count, by: first.count).map { start in
          let own = UnsafeBufferPointer(rebasing: all[start..<(start + first.count)])
          return DevelopmentNativeDehazeErosion.groupRange(own, offset: 0, width: 17, height: 17, expectsRange: true)
        }
        let expected: [Bool?] = (0..<4).map { $0 == missing ? nil : true }
        XCTAssertEqual(decisions, expected)
      }
    }
  }

  func testOnlyQualifiedPositiveFiniteAirlightCanMoveAfterHalfMinimum() {
    func light(_ green: Double) -> DevelopmentDehazeAirlightV1 { .init(red: 1, green: green, blue: 1) }
    XCTAssertTrue(DevelopmentNativeDehazeErosion.supportsAirlight(light(0.25)))
    for invalid in [Double(Float(0.25).nextDown), 0, -.infinity, .infinity, .nan] {
      XCTAssertFalse(DevelopmentNativeDehazeErosion.supportsAirlight(light(invalid)))
    }
  }

  func testRequestRejectsARetiredSourceEvenWhileTheCaptureIsCurrent() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let size = DevelopmentPixelSize(width: 9504, height: 6336)
    guard DevelopmentNativeDehazeErosion.enabled,
          DevelopmentNativeDehazeErosion.Layout(device: device, size: size) != nil else {
      throw XCTSkip("Requires the enabled native erosion on its qualified device")
    }
    let digest = String(repeating: "a", count: 64)
    let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    let image = CIImage(color: .black).cropped(to: extent)
    let pool = FlashRawCanonicalTexturePool()
    let key = FlashRawCanonicalTextureKey(sourceKey: digest,
      captureStamp: .init(device: 1, inode: 2, size: 3, seconds: 4, nanoseconds: 5,
                          changedSeconds: 6, changedNanoseconds: 7),
      contract: "dehaze-source-retirement", width: size.width, height: size.height)
    let pin = try pool.acquire(key) { image }
    defer { pin.release() }
    var adjustments = DevelopmentAdjustmentsV3()
    adjustments.rawDecoder = .flashRaw031
    adjustments.advancedDetail.dehaze = .init(enabled: true, amount: 25)
    adjustments.advancedDetail.preparedDehaze = .init(
      sourceBinding: .init(sourceContentID: digest, exifOrientation: 1, orientedWidth: size.width, orientedHeight: size.height),
      inputFingerprint: digest, airlight: .init(red: 0.5, green: 0.75, blue: 1),
      algorithmVersion: DevelopmentDehazeAlgorithm.positiveColorGuideV2.rawValue)
    let request = try XCTUnwrap(DevelopmentNativeDehazeErosion.Request(pin: pin, image: image, device: device,
      adjustments: adjustments, checkAuthority: {}))
    try request.requireCurrent()
    pool.retire(sourceKey: digest)
    XCTAssertThrowsError(try request.requireCurrent()) {
      XCTAssertEqual($0 as? PreviewPresentationError, .allocationProtocol)
    }
    XCTAssertGreaterThan(pool.statistics().pinnedBytes, 0)
  }

  func testUnobservedGridsAndReservationsOutsideWorkingSetDecline() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    XCTAssertNil(DevelopmentNativeDehazeErosion.Layout(device: device, size: .init(width: 9504, height: 6335)))
    XCTAssertNil(DevelopmentNativeDehazeErosion.Layout(device: device, size: .init(width: 6336, height: 9504)))
    for size in [DevelopmentPixelSize(width: 9504, height: 6336), .init(width: 8640, height: 5760)] {
      guard let stock = DevelopmentNativeDehazeErosion.Layout(device: device, size: size, grouped: false, useRing: true),
            let four = DevelopmentNativeDehazeErosion.Layout(device: device, size: size, grouped: true, useRing: false),
            let ring = DevelopmentNativeDehazeErosion.Layout(device: device, size: size, grouped: true, useRing: true) else {
        throw XCTSkip("Qualified macOS and Metal model required to inspect the native allocation plan")
      }
      XCTAssertEqual(stock.slabsPerCommand, 1)
      XCTAssertEqual(four.slabsPerCommand, 4)
      XCTAssertEqual(stock.flagsPerSlab, four.flagsPerSlab)
      XCTAssertNotEqual(stock.contract, four.contract)
      XCTAssertGreaterThan(four.allocationBytes, stock.allocationBytes)
      XCTAssertLessThanOrEqual(four.allocationBytes, 512 * 1024 * 1024)
      XCTAssertFalse(four.hasRoom(device: device, reserve: Int.max))

      XCTAssertNil(stock.ring)
      XCTAssertNil(four.ring)
      let plan = try XCTUnwrap(ring.ring)
      XCTAssertNotEqual(four.contract, ring.contract)
      XCTAssertEqual(ring.allocationBytes, plan.allocationBytes)
      XCTAssertLessThanOrEqual(plan.allocationBytes, 512 * 1024 * 1024)
      XCTAssertFalse(ring.hasRoom(device: device, reserve: Int.max))
      XCTAssertEqual(plan.levels.dropLast().map(\.storageRows), size.width == 9504 ? [70,82,118,136] : [70,82,118,122])

      var next = plan.levels.map { -$0.margin }
      var confirmed = Array(repeating: 0, count: plan.levels.count)
      for tick in stride(from: plan.firstTick, to: size.height, by: DevelopmentDehazeErosionRing.rowsPerTick) {
        for (index, level) in plan.levels.enumerated() {
          guard let rows = level.outputRows(tick: tick, height: size.height) else { continue }
          XCTAssertEqual(rows.lowerBound, next[index])
          if index > 0 {
            let previous = plan.levels[index - 1]
            let lower = rows.lowerBound - level.radius
            XCTAssertGreaterThanOrEqual(lower, -previous.margin)
            XCTAssertLessThanOrEqual(rows.upperBound + level.radius, next[index - 1])
            XCTAssertLessThanOrEqual(next[index - 1] - lower, previous.storageRows)
          }
          confirmed[index] += rows.count * level.width
          next[index] = rows.upperBound
        }
      }
      XCTAssertEqual(next, plan.levels.map { size.height + $0.margin })
      XCTAssertEqual(confirmed.reduce(0, +), size.width == 9504 ? 308_944_296 : 255_161_704)
      XCTAssertEqual(DevelopmentDehazeErosionRing.physicalRow(-1, storageRows: 70), 69)
      XCTAssertEqual(DevelopmentDehazeErosionRing.physicalRow(-140, storageRows: 70), 0)
    }
  }
}

