import XCTest
import Foundation
import CoreFoundation
@testable import RAWMasterImaging

final class ApplicationCacheProfileTests:XCTestCase {
  private typealias Profile=DevelopmentPreviewApplicationCacheProfile
  private let matching=Profile.Host(model:"Mac16,5",physicalBytes:137_438_953_472,
    os:.init(majorVersion:27,minorVersion:0,patchVersion:1))
  private func choose(bundle:String?=Profile.normalBundle,enabled:Any?=NSNumber(value:true),
                      profile:Any?=Profile.profile,host:Profile.Host?=nil)->Int {
    Profile.selectedBytes(bundleID:bundle,enabled:enabled,profile:profile,host:host ?? matching)
  }
  func testOnlyExactBothBundleProfilesAndGenuineBooleanCanOptIn() {
    let yes=NSNumber(value:true)
    XCTAssertEqual(CFGetTypeID(yes),CFBooleanGetTypeID())
    for bundle in [Profile.normalBundle,Profile.previewBundle,Profile.preview021Bundle] {
      XCTAssertEqual(choose(bundle:bundle,enabled:yes),1_073_741_824)
      XCTAssertEqual(choose(bundle:bundle,enabled:true),1_073_741_824)
      XCTAssertEqual(choose(bundle:bundle,profile:NSString(string:Profile.profile)),1_073_741_824)
    }
  }
  func testPreview021RequiresItsOwnExactSavedValuesAndSameHostContract() {
    XCTAssertEqual(Profile.preview021Bundle,"io.robinqu.RAWMaster.preview021")
    XCTAssertEqual(choose(bundle:Profile.preview021Bundle),1_073_741_824)
    // Pure selector only: nil is the own-domain absence. It cannot borrow the
    // normal/020 domain's persisted values; the live adapter remains unchanged.
    let rejected:[Any?]=[nil,false,NSNumber(value:1),NSNumber(value:1.0),"true"]
    for value in rejected {
      XCTAssertEqual(choose(bundle:Profile.preview021Bundle,enabled:value),0)
    }
    XCTAssertEqual(choose(bundle:Profile.preview021Bundle,enabled:nil,profile:nil),0)
    XCTAssertEqual(choose(bundle:Profile.preview021Bundle,profile:Profile.profile+" "),0)
    XCTAssertEqual(choose(bundle:Profile.preview021Bundle,profile:"m4max128-macos27.0.1-whole-f32-v2"),0)
    XCTAssertEqual(choose(bundle:Profile.preview021Bundle,host:.init(model:"Mac16,6",physicalBytes:137_438_953_472,os:matching.os)),0)
    XCTAssertEqual(choose(bundle:Profile.preview021Bundle,host:.init(model:"Mac16,5",physicalBytes:137_438_953_472,os:.init(majorVersion:27,minorVersion:0,patchVersion:2))),0)
    for bundle in ["io.robinqu.RAWMaster.preview021.extra","io.robinqu.RAWMaster.preview021 ","io.robinqu.RAWMaster.Preview021"] {
      XCTAssertEqual(choose(bundle:bundle),0)
    }
  }
  func testNilFalseAndCoercibleNonBooleanInputsCannotEnable() {
    let integer=NSNumber(value:1),floating=NSNumber(value:1.0)
    XCTAssertNotEqual(CFGetTypeID(integer),CFBooleanGetTypeID(),"fixture must be CFNumber, not bridged Bool")
    XCTAssertNotEqual(CFGetTypeID(floating),CFBooleanGetTypeID())
    let invalid:[Any?]=[nil,false,NSNumber(value:false),0,1,1.0,integer,floating,
      NSNumber(value:Int8(1)),NSDecimalNumber(value:1),"true","TRUE","YES","1",NSString(string:"true"),
      "false",[true],["enabled":true],Data([1]),Date(timeIntervalSince1970:0),NSNull()]
    for value in invalid {XCTAssertEqual(choose(enabled:value),0,"coercion/type mismatch must stay off: \(String(describing:value))")}
  }
  func testUnknownAppAndProfileCombinationsStayOffOnTheOtherwiseMatchingMachine() {
    let bundles:[String?]=[nil,"","io.robinqu.RAWMaster.preview020","io.robinqu.RAWMaster.preview020final.extra",
      "io.robinqu.rawmaster","com.apple.dt.xctest.tool","io.robinqu.RAWMaster "]
    for bundle in bundles {XCTAssertEqual(choose(bundle:bundle),0)}
    let profiles:[Any?]=[nil,"",Profile.profile+" "," "+Profile.profile,
      "m4max128-macos27.0.1-whole-f32-v2","m4max128-macos27.0.2-whole-f32-v1",true,1,[Profile.profile],NSNull()]
    for profile in profiles {XCTAssertEqual(choose(profile:profile),0)}
    // Explicitly absent app-domain values do not borrow true/profile from registration/global/env.
    XCTAssertEqual(choose(enabled:nil,profile:nil),0)
  }
  func testEveryUnknownHostAndOSFieldFailsClosedEvenWhenPreferencesAreValid() {
    let os=OperatingSystemVersion(majorVersion:27,minorVersion:0,patchVersion:1)
    let wrongHosts:[Profile.Host]=[
      .init(model:nil,physicalBytes:137_438_953_472,os:os),
      .init(model:"",physicalBytes:137_438_953_472,os:os),
      .init(model:"Mac16,6",physicalBytes:137_438_953_472,os:os),
      .init(model:"mac16,5",physicalBytes:137_438_953_472,os:os),
      .init(model:"Mac16,5",physicalBytes:nil,os:os),
      .init(model:"Mac16,5",physicalBytes:128_000_000_000,os:os),
      .init(model:"Mac16,5",physicalBytes:137_438_953_471,os:os),
      .init(model:"Mac16,5",physicalBytes:137_438_953_473,os:os),
      .init(model:"Mac16,5",physicalBytes:274_877_906_944,os:os),
      .init(model:"Mac16,5",physicalBytes:137_438_953_472,os:nil)]
    for host in wrongHosts {XCTAssertEqual(choose(host:host),0)}
    for wrongOS in [OperatingSystemVersion(majorVersion:26,minorVersion:0,patchVersion:1),
      .init(majorVersion:28,minorVersion:0,patchVersion:1),.init(majorVersion:27,minorVersion:1,patchVersion:1),
      .init(majorVersion:27,minorVersion:0,patchVersion:0),.init(majorVersion:27,minorVersion:0,patchVersion:2)] {
      XCTAssertEqual(choose(host:.init(model:"Mac16,5",physicalBytes:137_438_953_472,os:wrongOS)),0)
    }
    // Invalid opt-in cannot turn a wrong/unknown host on in combination with another invalid field.
    let invalidCombinedValues:[Any?]=[nil,false,1,"true"]
    for host in wrongHosts {for enabled in invalidCombinedValues {
      XCTAssertEqual(choose(enabled:enabled,host:host),0)
      XCTAssertEqual(choose(bundle:nil,enabled:enabled,profile:nil,host:host),0)
    }}
  }
  func testPublicAndIsolatedPolicyDefaultRemainsZero() {
    XCTAssertEqual(PreviewResourcePolicy.default.rawBaseCacheBytes,0)
    XCTAssertEqual(PreviewResourcePolicy().rawBaseCacheBytes,0)
    // No shared/global/defaults integration here. Existing isolated service budget/lifetime tests
    // remain the proof that init(policy:.default) does not consult this live application adapter.
  }
}
