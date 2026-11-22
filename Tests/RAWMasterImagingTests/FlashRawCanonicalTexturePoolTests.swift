import CoreImage
import XCTest
@testable import RAWMasterImaging

final class FlashRawCanonicalTexturePoolTests: XCTestCase {
  private func key(_ source:String)->FlashRawCanonicalTextureKey {
    .init(sourceKey:source,captureStamp:.init(device:1,inode:1,size:1,seconds:1,nanoseconds:1,changedSeconds:1,changedNanoseconds:1),contract:"test",width:1,height:1)
  }
  private func image()->CIImage { CIImage(color:.gray).cropped(to:.init(x:0,y:0,width:1,height:1)) }
  func testDirectTexturePoolHonorsBudgetPinsLRUAndSourceRetirement()throws {
    let pool=FlashRawCanonicalTexturePool(byteBudget:16,maximumEntries:2)
    let a=key("a"),b=key("b"),c=key("c")
    let first=try pool.acquire(a){self.image()}
    let second=try pool.acquire(a){XCTFail("duplicate fill");return self.image()}
    let other=try pool.acquire(b){self.image()}
    XCTAssertEqual(pool.statistics().hits,1);XCTAssertEqual(pool.statistics().fills,2)
    XCTAssertEqual(pool.statistics().residentBytes,16)
    XCTAssertThrowsError(try pool.acquire(c){self.image()}) // Pinned entries must not be evicted.
    first.release();second.release()
    XCTAssertEqual(pool.statistics().pinnedBytes,8) // B remains pinned until its explicit release.
    // Both A entries are unpinned now, so the LRU may be replaced.
    let replacement=try pool.acquire(c){self.image()}
    XCTAssertEqual(pool.statistics().fills,3);XCTAssertEqual(pool.statistics().evictions,1)
    pool.retire(sourceKey:"b");other.release()
    replacement.release()
    let stats=pool.statistics();XCTAssertEqual(stats.pinnedBytes,0);XCTAssertEqual(stats.residentBytes,8)
  }
  func testRetirementDuringDecodeDoesNotBlockAndReleasesReturnedPin() throws {
    let pool = FlashRawCanonicalTexturePool(byteBudget: 8, maximumEntries: 1)
    let key = key("in-flight")
    let joined = expectation(description: "release returned pin")
    let retired = expectation(description: "retire during decode")
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { joined.fulfill() }
      do {
        let pin = try pool.acquire(key) {
          entered.signal()
          guard resume.wait(timeout: .now() + 5) == .success else { throw RawBaseCacheError.capacity }
          return self.image()
        }
        pin.release()
      } catch { XCTFail("unexpected acquisition error: \(error)") }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    DispatchQueue.global().async {
      pool.retire(sourceKey: key.sourceKey)
      retired.fulfill()
    }
    wait(for: [retired], timeout: 2)
    resume.signal()
    wait(for: [joined], timeout: 3)
    XCTAssertEqual(pool.statistics().pinnedBytes, 0)
    XCTAssertEqual(pool.statistics().residentBytes, 0)
    XCTAssertEqual(pool.statistics().evictions, 1)
  }

}
