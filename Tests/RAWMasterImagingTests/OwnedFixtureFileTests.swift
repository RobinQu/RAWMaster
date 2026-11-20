import XCTest
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

final class OwnedFixtureFileTests:XCTestCase{
  private func root()throws->URL{let r=FileManager.default.temporaryDirectory.appendingPathComponent("owned-fixture-"+UUID().uuidString);try FileManager.default.createDirectory(at:r,withIntermediateDirectories:true);return r}
  private func snapshot(_ url:URL,_ data:Data)->EditingSourceSnapshot{.init(projectID:"owned-tiny",assetID:"tiny",contentSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),byteCount:Int64(data.count),admissionFingerprint:"test",sourceLocation:url)}
  private func identity(_ url:URL)throws->(UInt64,UInt64,UInt16,UInt16){var s=stat();guard Darwin.lstat(url.path,&s)==0 else{throw CocoaError(.fileReadUnknown)};return(UInt64(s.st_dev),s.st_ino,s.st_nlink,s.st_mode)}
  func testInputSymlinkProducesIndependentRegularAndMutationRestoreNeverTouchesSource()throws{
    let r=try root();defer{try? FileManager.default.removeItem(at:r)}
    let data=Data((0..<4099).map{UInt8($0%251)}),original=r.appendingPathComponent("original.raw"),alias=r.appendingPathComponent("alias.raw"),destination=r.appendingPathComponent("owned.raw")
    try data.write(to:original);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:original)
    let source=snapshot(alias,data),before=try PreviewFileStamp.read(original),mode=try identity(original).3
    let owned=try OwnedFixtureFile.create(from:source,to:destination,protecting:[source]);let first=try identity(destination)
    XCTAssertEqual(first.2,1);XCTAssertEqual(first.3 & UInt16(S_IFMT),UInt16(S_IFREG));XCTAssertNotEqual(first.1,try identity(original).1);XCTAssertEqual(try Data(contentsOf:destination),data)
    try owned.setPermissions(0o400);try owned.setPermissions(0o600);try owned.append(Data([0]));try owned.truncate(to:Int64(data.count));try owned.append(Data([0]));try owned.restore()
    let restored=try identity(destination);XCTAssertNotEqual(restored.1,first.1);XCTAssertEqual(restored.2,1);XCTAssertEqual(try Data(contentsOf:destination),data)
    XCTAssertEqual(try Data(contentsOf:original),data);XCTAssertEqual(try PreviewFileStamp.read(original),before);XCTAssertEqual(try identity(original).3,mode)
  }
  func testExistingSymlinkOutputIsRejectedWithoutFollowingOrWritingTarget()throws{
    let r=try root();defer{try? FileManager.default.removeItem(at:r)}
    let data=Data("untouched original".utf8),original=r.appendingPathComponent("source"),destination=r.appendingPathComponent("destination")
    try data.write(to:original);try FileManager.default.createSymbolicLink(at:destination,withDestinationURL:original)
    let source=snapshot(original,data),before=try PreviewFileStamp.read(original),mode=try identity(original).3
    XCTAssertThrowsError(try OwnedFixtureFile.create(from:source,to:destination,protecting:[source]));XCTAssertEqual(try Data(contentsOf:original),data);XCTAssertEqual(try PreviewFileStamp.read(original),before);XCTAssertEqual(try identity(original).3,mode)
  }
  func testReplacedSymlinkHardlinkOrDifferentInodeRejectsEveryFaultAndRestore()throws{
    for replacement in ["symlink","hardlink","new-regular"]{
      let r=try root();defer{try? FileManager.default.removeItem(at:r)}
      let data=Data("protected input bytes".utf8),original=r.appendingPathComponent("original"),dest=r.appendingPathComponent("owned"),moved=r.appendingPathComponent("old-owned")
      try data.write(to:original);let source=snapshot(original,data),owned=try OwnedFixtureFile.create(from:source,to:dest,protecting:[source]),sourceBefore=try PreviewFileStamp.read(original),mode=try identity(original).3
      try FileManager.default.moveItem(at:dest,to:moved)
      if replacement=="symlink"{try FileManager.default.createSymbolicLink(at:dest,withDestinationURL:original)}
      else if replacement=="hardlink"{try FileManager.default.linkItem(at:original,to:dest)}
      else{try data.write(to:dest)}
      // Creating/removing the hostile hardlink changes source ctime; take the state after setup.
      let afterSetup=try PreviewFileStamp.read(original)
      XCTAssertThrowsError(try owned.append(Data([0])));XCTAssertThrowsError(try owned.setPermissions(0o400));XCTAssertThrowsError(try owned.truncate(to:0));XCTAssertThrowsError(try owned.restore())
      XCTAssertEqual(try Data(contentsOf:original),data);XCTAssertEqual(try identity(original).3,mode);XCTAssertEqual(try PreviewFileStamp.read(original),afterSetup)
      if replacement != "hardlink"{XCTAssertEqual(afterSetup,sourceBefore)}
      XCTAssertEqual(try Data(contentsOf:moved),data)
    }
  }
  func testProtectedInputRedirectionFailsClosedBeforeMutatingOwnedBytes()throws{
    let r=try root();defer{try? FileManager.default.removeItem(at:r)}
    let data=Data("original".utf8),sourceURL=r.appendingPathComponent("source"),other=r.appendingPathComponent("other"),alias=r.appendingPathComponent("alias"),out=r.appendingPathComponent("out")
    try data.write(to:sourceURL);try data.write(to:other);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:sourceURL)
    let source=snapshot(alias,data),owned=try OwnedFixtureFile.create(from:source,to:out,protecting:[snapshot(sourceURL,data)])
    try FileManager.default.removeItem(at:alias);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:other)
    XCTAssertThrowsError(try owned.append(Data([0])));XCTAssertEqual(try Data(contentsOf:out),data);XCTAssertEqual(try Data(contentsOf:sourceURL),data);XCTAssertEqual(try Data(contentsOf:other),data)
  }
}
