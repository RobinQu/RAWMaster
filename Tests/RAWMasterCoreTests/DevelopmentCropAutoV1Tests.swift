import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentCropAutoV1Tests: XCTestCase {
  private let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:6,orientedWidth:1001,orientedHeight:667)
  private func result(_ geometry:DevelopmentGeometryV3,baseline:DevelopmentGeometryV3,input:DevelopmentCropAutoInputV1,
                      first:Double = 4,second:Double = 4.2,confidence:Double = 0.9,
                      verificationPair:DevelopmentCropAutoVerificationPairV1 = .init(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:-2.8,confidence:0.9),negativeRoll:.init(knownRollDegrees:-3,correctionDegrees:3.2,confidence:0.9)))->DevelopmentResolvedGeometryV1 {
    .init(binding:.init(sourceContentID:source.sourceContentID,sourceGeneration:3,expectedRecipeFingerprint:String(repeating:"b",count:64),stage:.orientedSourceBeforeGeometry),
      source:source,presentedRecipeFingerprint:String(repeating:"c",count:64),input:input,
      resolution:.candidate(geometry,.init(firstDegrees:first,secondDegrees:second,firstConfidence:confidence,secondConfidence:confidence,verificationPair:verificationPair)))
  }
  func testHorizonComparisonUsesHalfTurnPeriod() {
    XCTAssertEqual(DevelopmentCropGeometryAutoV1.horizonDifference(89.8,-89.8),-0.4,accuracy:1e-10)
    XCTAssertEqual(DevelopmentCropGeometryAutoV1.horizonDifference(180.2,0.2),0,accuracy:1e-10)
    XCTAssertEqual(DevelopmentCropGeometryAutoV1.horizonDifference(-180.2,-0.2),0,accuracy:1e-10)
  }
  func testFinitePureRotationAndEveryLateD4HaveExplicitSign() throws {
    for degrees in [-12.0,4,12] {
      let a=degrees * .pi/180,c=cos(a),s=sin(a)
      for orientation in DevelopmentD4OrientationV3.allCases {
        let actual=try DevelopmentCropGeometryAutoV1.absoluteStraighten(bottomLeftLinear:[c,s,-s,c],late:orientation)
        XCTAssertEqual(actual,orientation.isReflection ? -degrees:degrees,accuracy:1e-10)
      }
    }
    for invalid in [[Double.nan,0,0,1],[2.0,0,0,1],[1.0,0,0.1,1],[-1.0,0,0,1],[1.0,0,0]] {
      XCTAssertThrowsError(try DevelopmentCropGeometryAutoV1.absoluteStraighten(bottomLeftLinear:invalid,late:.identity))
    }
  }
  func testAbsoluteAnglePreservesUserD4AndCropAndMapsOnceAtOddNativeSize() throws {
    for turns in 0...3 { for late in DevelopmentD4OrientationV3.allCases {
      let baseline=DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:2,crop:.init(x:0.1,y:0.2,width:0.7,height:0.6),clockwiseQuarterTurns:turns,flipHorizontal:true,flipVertical:true,lateOrientation:.init(orientation:late))
      let input=try DevelopmentCropAutoInputV1(geometry:baseline,aspectRatio:nil)
      let candidate=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:4,aspectRatio:nil)
      var expected=baseline;expected.straightenDegrees=4
      XCTAssertEqual(candidate,expected)
      XCTAssertEqual(try result(candidate,baseline:baseline,input:input).validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:input),candidate)
      let map=try candidate.mapping(sourceSize:source.sourceSize)
      for p in [DevelopmentSourcePoint(x:0,y:0),.init(x:0.3,y:0.7),.init(x:1,y:1)] {
        let original=try map.sourcePoint(fromOutput:p),back=try XCTUnwrap(map.outputPoint(fromSource:original))
        XCTAssertEqual(back.x,p.x,accuracy:1e-9);XCTAssertEqual(back.y,p.y,accuracy:1e-9)
      }
    } }
  }
  func testAspectFitUsesContinuousPlaneAndIsNotRepeatedShrink() throws {
    let baseline=DevelopmentGeometryV3(straightenDegrees:1,crop:.init(x:0.12,y:0.13,width:0.75,height:0.72))
    let a=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:4,aspectRatio:1.5)
    let b=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:4,aspectRatio:1.5)
    XCTAssertEqual(a,b)
    var whole=a;whole.crop = .init();let plane=try whole.mapping(sourceSize:source.sourceSize).cropPlane
    XCTAssertEqual(a.crop.width*plane.rect.width/(a.crop.height*plane.rect.height),1.5,accuracy:1e-12)
    XCTAssertLessThanOrEqual(a.crop.width,baseline.crop.width);XCTAssertLessThanOrEqual(a.crop.height,baseline.crop.height)
  }
  func testWholeCandidateRejectsChangedUserFieldsStaleInputAndUntrustedEvidence() throws {
    let baseline=DevelopmentGeometryV3(),input=try DevelopmentCropAutoInputV1(geometry:baseline,aspectRatio:nil)
    let good=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:4,aspectRatio:nil)
    var wrong=good;wrong.flipHorizontal=true
    XCTAssertThrowsError(try result(wrong,baseline:baseline,input:input).validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:input))
    var stale=source;stale.sourceContentID=String(repeating:"d",count:64)
    XCTAssertThrowsError(try result(good,baseline:baseline,input:input).validatedCandidate(baseline:baseline,expectedSource:stale,expectedInput:input))
    for (second,confidence) in [(5.0,0.9),(4.1,0.79),(Double.nan,0.9)] {
      XCTAssertThrowsError(try result(good,baseline:baseline,input:input,second:second,confidence:confidence).validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:input))
    }
    let wrongInput=try DevelopmentCropAutoInputV1(geometry:baseline,aspectRatio:1)
    XCTAssertThrowsError(try result(good,baseline:baseline,input:input).validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:wrongInput))
  }
  func testControlledRollPairRetainsActualObservationsAndDerivesSummaries() throws {
    let pair=DevelopmentCropAutoVerificationPairV1(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:-2.75,confidence:0.95),negativeRoll:.init(knownRollDegrees:-3,correctionDegrees:2.5,confidence:0.8))
    try pair.validate() // residual difference is exactly the unchanged .75 degree bound.
    XCTAssertEqual(pair.positiveRoll.knownRollDegrees,3);XCTAssertEqual(pair.positiveRoll.correctionDegrees,-2.75)
    XCTAssertEqual(pair.positiveRoll.residualDegrees,0.25);XCTAssertEqual(pair.negativeRoll.residualDegrees,-0.5)
    let e=DevelopmentCropAutoEvidenceV1(firstDegrees:4,secondDegrees:4.2,firstConfidence:1,secondConfidence:0.9,verificationPair:pair)
    XCTAssertEqual(e.verificationPair,pair);XCTAssertEqual(e.residualDegrees,0.5);XCTAssertEqual(e.verificationConfidence,0.8)
    let wrapped=DevelopmentCropAutoVerificationPairV1(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:177,confidence:1),negativeRoll:.init(knownRollDegrees:-3,correctionDegrees:-177,confidence:1))
    try wrapped.validate();XCTAssertEqual(wrapped.residualDegrees,0)
  }
  func testControlledRollPairRejectsWrongRollSignConfidenceResidualAndDisagreementAtCandidateGate() throws {
    let baseline=DevelopmentGeometryV3(),input=try DevelopmentCropAutoInputV1(geometry:baseline,aspectRatio:nil)
    let good=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:4,aspectRatio:nil)
    let p=DevelopmentCropAutoVerificationObservationV1(knownRollDegrees:3,correctionDegrees:-3,confidence:1)
    let n=DevelopmentCropAutoVerificationObservationV1(knownRollDegrees:-3,correctionDegrees:3,confidence:1)
    let invalid:[DevelopmentCropAutoVerificationPairV1]=[
      .init(positiveRoll:n,negativeRoll:p), // Order and actual known rolls are contractual.
      .init(positiveRoll:.init(knownRollDegrees:2,correctionDegrees:-2,confidence:1),negativeRoll:n),
      .init(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:3,confidence:1),negativeRoll:n),
      .init(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:-3,confidence:0.79),negativeRoll:n),
      .init(positiveRoll:p,negativeRoll:.init(knownRollDegrees:-3,correctionDegrees:3.51,confidence:1)),
      .init(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:-2.6,confidence:1),negativeRoll:.init(knownRollDegrees:-3,correctionDegrees:2.6,confidence:1)),
      .init(positiveRoll:.init(knownRollDegrees:3,correctionDegrees:.nan,confidence:1),negativeRoll:n)
    ]
    for pair in invalid {
      XCTAssertThrowsError(try pair.validate())
      XCTAssertThrowsError(try result(good,baseline:baseline,input:input,verificationPair:pair).validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:input))
    }
  }
  func testControlledRollCorrectionIsInDisplayedSpaceAfterEveryLateD4() throws {
    for late in DevelopmentD4OrientationV3.allCases { for roll in [3.0,-3] {
      // Known roll is applied AFTER user D4: verification must use identity, not conjugate it again.
      let a = -roll * .pi/180,c=cos(a),s=sin(a)
      let displayed=try DevelopmentCropGeometryAutoV1.absoluteStraighten(bottomLeftLinear:[c,s,-s,c],late:.identity)
      let observation=DevelopmentCropAutoVerificationObservationV1(knownRollDegrees:roll,correctionDegrees:displayed,confidence:1)
      XCTAssertEqual(observation.residualDegrees,0,accuracy:1e-12)
      let beforeLate=try DevelopmentCropGeometryAutoV1.absoluteStraighten(bottomLeftLinear:[c,s,-s,c],late:late)
      XCTAssertEqual(beforeLate,late.isReflection ? roll:-roll,accuracy:1e-12)
    } }
  }
  func testNonzeroPerspectiveAndNoResultCannotProduceAWrite() throws {
    let baseline=DevelopmentGeometryV3(version:.projectiveV3_1,verticalPerspective:5),input=try DevelopmentCropAutoInputV1(geometry:baseline,aspectRatio:nil)
    XCTAssertFalse(DevelopmentCropGeometryAutoV1.supports(baseline))
    XCTAssertThrowsError(try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:4,aspectRatio:nil))
    let r=DevelopmentResolvedGeometryV1(binding:.init(sourceContentID:source.sourceContentID,sourceGeneration:1,expectedRecipeFingerprint:String(repeating:"b",count:64),stage:.orientedSourceBeforeGeometry),source:source,presentedRecipeFingerprint:String(repeating:"c",count:64),input:input,resolution:.noResult(.unsupportedGeometry))
    XCTAssertNil(try r.validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:input))
    XCTAssertEqual(baseline.verticalPerspective,5)
  }
}
