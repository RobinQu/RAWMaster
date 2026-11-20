import XCTest
@testable import RAWMasterCore

final class TimelapseTests: XCTestCase {
    private func asset(_ id: String, name: String? = nil, state: AssetAvailability = .available) -> AssetRecord {
        AssetRecord(id:id,sessionID:"s",projectID:"p",sourcePath:"/photos/"+(name ?? id+".jpg"),
                    decision:.reject,rating:0,availability:state,importState:.ready)
    }
    private func group(_ ids: [String], included: [String]? = nil) -> CaptureGroup {
        CaptureGroup(projectID:"p",name:"Sunset",kind:"延时",assetIDs:ids,includedAssetIDs:included ?? ids)
    }
    func testInputUsesExplicitOrderParticipationAndDoesNotTreatRejectionAsExclusion() throws {
        let a=asset("a"),b=asset("b"),c=asset("c")
        let input=try TimelapseInput.make(group:group(["c","a","b"],included:["b","c"]),eligibleAssets:[a,b,c])
        XCTAssertEqual(input.assets.map(\.id),["c","b"])
        XCTAssertEqual(input.sourceFileCount,2)
        XCTAssertTrue(input.assets.allSatisfy { $0.decision == .reject })
    }
    func testConfirmedPairsDeduplicateAtFirstOccurrenceAndNeverExpandParticipation() throws {
        let raw=asset("raw",name:"A.ARW"),jpg=asset("jpg",name:"A.JPG"),b=asset("b")
        let pair=CapturePair(sessionID:"s",rawAssetID:"raw",jpegAssetID:"jpg",isManual:true)
        let input=try TimelapseInput.make(group:group(["jpg","b","raw"]),eligibleAssets:[raw,jpg,b],pairs:[pair])
        XCTAssertEqual(input.assets.map(\.id),["raw","b"])
        XCTAssertEqual(input.sourceFileCount,3)
        let onlyJPEG=try TimelapseInput.make(group:group(["jpg","b","raw"],included:["jpg","b"]),eligibleAssets:[raw,jpg,b],pairs:[pair])
        XCTAssertEqual(onlyJPEG.assets.map(\.id),["jpg","b"])
        let unpaired=try TimelapseInput.make(group:group(["jpg","b","raw"]),eligibleAssets:[raw,jpg,b])
        XCTAssertEqual(unpaired.assets.map(\.id),["jpg","b","raw"],"Names alone must never infer paired captures")
    }
    func testUnavailableSelectedRAWAndMissingAdmissionBlockInsteadOfDroppingFrame() throws {
        let raw=asset("raw",name:"A.ARW",state:.missing),jpg=asset("jpg",name:"A.JPG"),b=asset("b")
        let pair=CapturePair(sessionID:"s",rawAssetID:"raw",jpegAssetID:"jpg",isManual:true)
        XCTAssertThrowsError(try TimelapseInput.make(group:group(["jpg","b","raw"]),eligibleAssets:[raw,jpg,b],pairs:[pair]))
        XCTAssertThrowsError(try TimelapseInput.make(group:group(["jpg","b","raw"]),eligibleAssets:[jpg,b]))
        XCTAssertThrowsError(try TimelapseInput.make(group:group(["jpg","jpg"]),eligibleAssets:[jpg]))
        XCTAssertThrowsError(try TimelapseInput.make(group:group(["jpg","b"],included:["jpg","absent"]),eligibleAssets:[jpg,b]))
    }
    func testDefaultsStrideCeilTimingAndEvenAspectDimensions() throws {
        var settings=TimelapseSettings()
        try settings.validate(inputCount:480)
        XCTAssertEqual(settings.duration(inputCount:480),16)
        settings.frameStride=4;settings.frameRate=25
        XCTAssertEqual(settings.outputFrameIndices(inputCount:11),[0,4,8])
        XCTAssertEqual(settings.duration(inputCount:11),3.0/25.0)
        XCTAssertThrowsError(try settings.validate(inputCount:4))
        for aspect in TimelapseAspect.allCases { for res in TimelapseResolution.allCases {
            settings.aspect=aspect;settings.resolution=res
            for preview in [true,false] { let d=settings.dimensions(preview:preview);XCTAssertEqual(d.width%2,0);XCTAssertEqual(d.height%2,0) }
        } }
    }
    func testSettingsRejectNonfiniteInvalidROIAndDuplicateKeyframes() throws {
        var s=TimelapseSettings();s.deflickerStrength = .nan
        XCTAssertThrowsError(try s.validate(inputCount:10))
        s=TimelapseSettings();s.maxCropFraction = .infinity
        XCTAssertThrowsError(try s.validate(inputCount:10))
        s=TimelapseSettings();s.alignment = .subject
        XCTAssertThrowsError(try s.validate(inputCount:10))
        s.subjectRegion=TimelapseRegion(x:0.4,y:0.4,width:0.3,height:0.3)
        XCTAssertNoThrow(try s.validate(inputCount:10))
        s.subjectRegion=TimelapseRegion(x:0.9,y:0.5,width:0.2,height:0.2)
        XCTAssertThrowsError(try s.validate(inputCount:10))
        s=TimelapseSettings();s.keyframes=[.init(position:0),.init(position:0,exposureEV:1)]
        XCTAssertThrowsError(try s.validate(inputCount:10))
        s.keyframes=[.init(position:.nan)]
        XCTAssertThrowsError(try s.validate(inputCount:10))
    }
    func testExposureKeyframesClampEndpointsAndInterpolateEV() throws {
        var s=TimelapseSettings();s.keyframes=[.init(position:0.2,exposureEV:-1),.init(position:0.8,exposureEV:1)]
        XCTAssertEqual(s.exposure(at:0),-1)
        XCTAssertEqual(s.exposure(at:0.5),0,accuracy:1e-10)
        XCTAssertEqual(s.exposure(at:1),1)
        XCTAssertLessThan(s.exposure(at:0.3),s.exposure(at:0.7))
        let data=try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(TimelapseSettings.self,from:data),s)
    }
}
