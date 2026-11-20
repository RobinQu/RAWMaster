import XCTest
import Foundation
import CryptoKit
@testable import RAWMasterCore

final class DevelopmentCurvesAlgorithmV3Tests:XCTestCase {
  // Frozen pre-key shape, independent of the new default encoder.
  private let golden = #"{"blue":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1},"enabled":true,"green":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1},"red":{"curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1},"rgb":{"curve":{"points":[{"x":0,"y":0},{"x":0.25,"y":0.6},{"x":1,"y":1}]},"inputBlack":0,"inputWhite":1}}"#
  private func encoded<T:Encodable>(_ x:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(x)}
  func testLegacyAbsentAndExplicitLegacyOmitKeyPreserveActiveBytesAndFingerprint()throws {
    let bytes=Data(golden.utf8),old=try JSONDecoder().decode(DevelopmentCurvesV3.self,from:bytes)
    XCTAssertEqual(old.algorithm,.legacyPCHIPV1);XCTAssertEqual(try encoded(old),bytes)
    let expected=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    XCTAssertEqual(try EditingFingerprint.of(old),expected)
    var object=try JSONSerialization.jsonObject(with:bytes)as! [String:Any];object["algorithm"]="legacy-pchip-v1"
    let explicit=try JSONDecoder().decode(DevelopmentCurvesV3.self,from:JSONSerialization.data(withJSONObject:object))
    XCTAssertEqual(explicit,old);XCTAssertEqual(try encoded(explicit),bytes);XCTAssertEqual(try EditingFingerprint.of(explicit),expected)
  }
  func testPresentNullUnknownNonStringAndUnknownKeysFailClosedEvenDisabled()throws {
    let original=try JSONSerialization.jsonObject(with:Data(golden.utf8))as! [String:Any]
    let invalidValues:[Any]=[NSNull(),"natural-cubic-v99",1,true]
    for value in invalidValues {
      var object=original;object["enabled"]=false;object["algorithm"]=value
      XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentCurvesV3.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    var extra=original;extra["unreviewedProfile"]="p3"
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentCurvesV3.self,from:JSONSerialization.data(withJSONObject:extra)))
  }
  func testExplicitTypedNewVersionRoundTripAndUnrelatedCommandsDoNotMigrateLegacy()throws {
    let group=try JSONDecoder().decode(DevelopmentCurvesV3.self,from:Data(golden.utf8))
    let old=DevelopmentRecipe(adjustmentsV3:.init(curves:group)),oldBytes=try encoded(old),oldFP=try EditingFingerprint.of(old)
    var changed=group;changed.algorithm = .naturalCubicGamma512LumaV1
    let new=try old.applying(.setParameters(.curves(changed)))
    XCTAssertEqual(new.adjustmentsV3?.curves.rgb,group.rgb);XCTAssertNotEqual(try EditingFingerprint.of(new),oldFP)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self,from:encoded(new)),new)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self,from:oldBytes),old)
    XCTAssertEqual(try encoded(old),oldBytes);XCTAssertEqual(try EditingFingerprint.of(old),oldFP)
    let untouched=try old.applying(.setEnabled(.color,false))
    XCTAssertEqual(untouched.adjustmentsV3?.curves.algorithm,.legacyPCHIPV1)
    let preserved=try new.applying(.setParameters(.color(.init(enabled:true,saturation:0.25))))
    XCTAssertEqual(preserved.adjustmentsV3?.curves.algorithm,.naturalCubicGamma512LumaV1)
    let genericReset=try new.applying(.reset(.curves))
    XCTAssertEqual(genericReset.adjustmentsV3?.curves.algorithm,.legacyPCHIPV1)
    let explicitNewReset=try new.applying(.setParameters(.curves(.init(algorithm:.naturalCubicGamma512LumaV1))))
    XCTAssertFalse(try XCTUnwrap(explicitNewReset.adjustmentsV3).curves.enabled)
    XCTAssertEqual(explicitNewReset.adjustmentsV3?.curves.algorithm,.naturalCubicGamma512LumaV1)
    // Undo/redo owners can retain these immutable whole snapshots; no decode changes old bytes.
    XCTAssertEqual(try encoded(old),oldBytes);XCTAssertEqual(try EditingFingerprint.of(new),try EditingFingerprint.of(JSONDecoder().decode(DevelopmentRecipe.self,from:encoded(new))))
  }
  func testAlgorithmIdentityIsIncludedInPreDehazeDependencyWithoutChangingLegacyWire()throws {
    let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:64,orientedHeight:48)
    let context=DevelopmentDehazeContextV1(source:source,sourceGeneration:1,decoderContractFingerprint:String(repeating:"b",count:64))
    var a=DevelopmentRecipe(adjustmentsV3:.init()),c=DevelopmentCurvesV3(algorithm:.naturalCubicGamma512LumaV1)
    c.enabled=true;c.rgb.curve = .init(points:[.init(x:0,y:0),.init(x:0.25,y:0.6),.init(x:1,y:1)])
    let oldInput=try a.prospectiveDehazeInputV1(context:context)
    a=try a.applying(.setParameters(.curves(c)))
    let newInput=try a.prospectiveDehazeInputV1(context:context)
    XCTAssertNotEqual(oldInput.input.inputFingerprint,newInput.input.inputFingerprint)
    let v1=DevelopmentRecipe(),v2=try v1.promotingToV2()
    XCTAssertFalse(String(decoding:try encoded(v1),as:UTF8.self).contains("algorithm"))
    XCTAssertFalse(String(decoding:try encoded(v2),as:UTF8.self).contains("algorithm"))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self,from:encoded(v1)),v1)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self,from:encoded(v2)),v2)
  }
}
