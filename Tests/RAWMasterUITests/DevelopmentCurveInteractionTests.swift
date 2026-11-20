import AppKit
import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

final class DevelopmentCurveInteractionTests: XCTestCase {
    func testDraggedPointCannotCrossNeighborsAndEndpointsOnlyChangeOutput() throws {
        let curve = DevelopmentCurve(points: [.init(x: 0, y: 0), .init(x: 0.3, y: 0.2), .init(x: 0.6, y: 0.8), .init(x: 1, y: 1)])
        let next = try XCTUnwrap(DevelopmentCurveInteraction.moving(curve, index: 1, x: 2, y: -4))
        try next.validate(); XCTAssertLessThan(next.points[1].x, next.points[2].x); XCTAssertEqual(next.points[1].y, 0)
        let endpoint = try XCTUnwrap(DevelopmentCurveInteraction.moving(curve, index: 0, x: 0.8, y: 0.15))
        XCTAssertEqual(endpoint.points[0], .init(x: 0, y: 0.15))
        XCTAssertNil(DevelopmentCurveInteraction.moving(curve, index: 1, x: .nan, y: 0.5))
        // The narrowest legal neighbors must not construct an inverted ClosedRange or crash.
        let narrow = DevelopmentCurve(points: [.init(x: 0, y: 0), .init(x: 0.0001, y: 0.4), .init(x: 0.0002, y: 0.5), .init(x: 1, y: 1)])
        try narrow.validate(); try XCTUnwrap(DevelopmentCurveInteraction.moving(narrow, index: 1, x: 0.5, y: 0.6)).validate()
    }
    func testAddDeleteBoundedPointsAndSharedSmoothCurveValues() throws {
        var curve = DevelopmentCurve()
        for _ in 0..<14 { curve = try XCTUnwrap(DevelopmentCurveInteraction.midpoint(curve)).0; try curve.validate() }
        XCTAssertEqual(curve.points.count, 16)
        XCTAssertNil(DevelopmentCurveInteraction.midpoint(curve))
        XCTAssertNil(DevelopmentCurveInteraction.deleting(curve, index: 0))
        XCTAssertNil(DevelopmentCurveInteraction.deleting(curve, index: 15))
        XCTAssertEqual(DevelopmentCurveInteraction.deleting(curve, index: 1)?.points.count, 15)
        let shaped = DevelopmentCurve(points: [.init(x: 0, y: 0), .init(x: 0.3, y: 0.15), .init(x: 0.7, y: 0.9), .init(x: 1, y: 1)])
        let added = try XCTUnwrap(DevelopmentCurveInteraction.midpoint(shaped))
        XCTAssertEqual(added.0.points[added.1].y, try shaped.value(at: added.0.points[added.1].x), accuracy: 1e-12)
    }
    @MainActor func testCurveKeyboardSelectionDeletionAndUndoNeverMutateAnotherChannel() throws {
        let control = DevelopmentCurveControl(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        control.curve = .init(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4), .init(x: 1, y: 1)]); control.selected = 1
        var callbacks = 0; control.onChange = { _ in callbacks += 1 }
        func key(_ code: UInt16, _ text: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        control.keyDown(with: try key(126)); XCTAssertGreaterThan(control.curve.points[1].y, 0.4)
        let changed = control.curve
        XCTAssertTrue(control.performKeyEquivalent(with: try key(6, "z", flags: .command)))
        XCTAssertTrue(control.performKeyEquivalent(with: try key(6, "z", flags: [.command, .shift])))
        control.keyDown(with: try key(35, "p")); control.keyDown(with: try key(7, "x"))
        XCTAssertEqual(control.curve, changed); XCTAssertEqual(callbacks, 1)
        control.keyDown(with: try key(51)); XCTAssertEqual(control.curve.points.count, 2)
        control.keyDown(with: try key(51)); XCTAssertEqual(control.curve.points.count, 2)
    }

    func testExplicitNewMidpointUsesDisplayFunctionAndRejectsStaleOrUnrepresentableValues() throws {
        let curve=DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0.3,y:0.15),.init(x:0.7,y:0.9),.init(x:1,y:1)])
        let display=try DevelopmentCurveDisplayModel(curve:curve,algorithm:.naturalCubicGamma512LumaV1)
        let result=try XCTUnwrap(DevelopmentCurveInteraction.midpoint(curve,displayModel:display))
        let point=result.0.points[result.1]
        XCTAssertEqual(point.y,try display.value(at:point.x))
        XCTAssertGreaterThan(abs(point.y-(try curve.value(at:point.x))),0.001)
        XCTAssertNil(DevelopmentCurveInteraction.midpoint(.init(),displayModel:display))
        let overshoot=DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0.1,y:1),.init(x:0.2,y:0),.init(x:1,y:1)])
        let extreme=try DevelopmentCurveDisplayModel(curve:overshoot,algorithm:.naturalCubicGamma512LumaV1)
        let y=try extreme.value(at:0.6)
        XCTAssertTrue(y<0 || y>1,"Fixture must exercise actual unrepresentable ordinate")
        XCTAssertNil(DevelopmentCurveInteraction.midpoint(overshoot,displayModel:extreme))
    }
    @MainActor func testCurveControlDefaultLegacyAndExplicitNewDisplayHaveNoFallbackOrMutation() throws {
        let control=DevelopmentCurveControl(frame:.init(x:0,y:0,width:240,height:180))
        let curve=DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0.3,y:0.15),.init(x:0.7,y:0.9),.init(x:1,y:1)])
        control.curve=curve;XCTAssertNil(control.displayModel)
        XCTAssertEqual(try control.displayedValue(at:0.5),try curve.value(at:0.5))
        let display=try DevelopmentCurveDisplayModel(curve:curve,algorithm:.naturalCubicGamma512LumaV1)
        control.displayModel = .success(display)
        XCTAssertEqual(try control.displayedValue(at:0.5),try display.value(at:0.5))
        control.displayModel = .failure(EditingError.invalidRecipe)
        XCTAssertThrowsError(try control.displayedValue(at:0.5))
        control.displayModel = .success(try .init(curve:.init(),algorithm:.naturalCubicGamma512LumaV1))
        XCTAssertThrowsError(try control.displayedValue(at:0.5))
        XCTAssertEqual(control.curve,curve)
        control.displayModel=nil
        XCTAssertEqual(try control.displayedValue(at:0.5),try curve.value(at:0.5))
    }
    func testDirectCurveEditSelectsCurrentAlgorithmWithoutMutatingSavedLegacy() throws {
        let saved=DevelopmentCurvesV3()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let before=try encoder.encode(saved)
        let direct=saved.forDirectUserEdit()
        XCTAssertEqual(saved.algorithm,.legacyPCHIPV1)
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(try encoder.encode(saved),before)
        XCTAssertEqual(direct.algorithm,.naturalCubicGamma512LumaV1)
        XCTAssertTrue(direct.enabled)
        XCTAssertEqual(direct.rgb.curve,saved.rgb.curve)
    }
}
