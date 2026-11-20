import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class PhotosTypedValueBindingTests: XCTestCase {
    @MainActor private final class Draft {
        var recipe: DevelopmentRecipe
        var writes = 0
        var errors: [Error] = []
        init(definitionEnabled: Bool = true) {
            var parameters = DevelopmentAdjustmentsV3()
            parameters.curves = .init(enabled: true,
                rgb: .init(curve: .init(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.573), .init(x: 1, y: 1)])),
                red: .init(inputBlack: 0.1, inputWhite: 0.9), algorithm: .naturalCubicGamma512LumaV1)
            parameters.definition = .init(enabled: definitionEnabled, amount: 0.41)
            recipe = .init(adjustmentsV3: parameters)
        }
    }
    @MainActor private func make(definitionEnabled: Bool = true) throws
        -> (Draft, EditingDevelopmentSession, EditingInteractionContext, PhotosCurveParameterControls) {
        let draft = Draft(definitionEnabled: definitionEnabled)
        let session = EditingDevelopmentSession(readRecipe: { draft.recipe }, commitRecipe: { next, _ in
            draft.recipe = next; draft.writes += 1
        })
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64),
            exifOrientation: 1, orientedWidth: 120, orientedHeight: 80)
        let context = try session.activate(workID: "typed-binding", admissionFingerprint: String(repeating: "b", count: 64),
            source: source, sourceGeneration: 1, noiseReduction: .image)
        let controls = PhotosCurveParameterControls(session: session, context: context, onError: { draft.errors.append($0) })
        return (draft, session, context, controls)
    }

    @MainActor func testProductionPointBindingReadsSynchronousChangesAndOneUndoRedo() throws {
        for definitionEnabled in [false, true] {
            let (draft, session, context, controls) = try make(definitionEnabled: definitionEnabled)
            let before = draft.recipe
            let row = controls.pointRow("输出", value: 0.573, range: 0...1, coordinate: false, channelPath: \.rgb, index: 1)
            var token: EditingGestureToken?
            // Keep the production binding object alive throughout writes and history changes.
            let binding = row.makeBinding(gesture: { token })
            XCTAssertEqual(binding.wrappedValue, 0.573)
            token = try session.beginGesture(.init(group: .curves, name: "曲线 · 输出"), context: context)
            binding.wrappedValue = 0.551
            XCTAssertEqual(binding.wrappedValue.bitPattern, 0.551.bitPattern)
            binding.wrappedValue = 0.549
            XCTAssertEqual(binding.wrappedValue.bitPattern, 0.549.bitPattern)
            var expected = before
            expected.adjustmentsV3?.curves.rgb.curve.points[1].y = 0.549
            XCTAssertEqual(draft.recipe, expected, "Only the chosen ordinate may change, including with Definition enabled")
            XCTAssertEqual(draft.writes, 2); XCTAssertEqual(session.history.entryCount, 0)
            try session.endGesture(try XCTUnwrap(token), .commit); token = nil
            XCTAssertEqual(binding.wrappedValue, 0.549)
            XCTAssertEqual(session.history.entryCount, 1)
            // A repeated accepted endpoint remains a no-op after the gesture closes.
            binding.wrappedValue = binding.wrappedValue
            XCTAssertEqual(draft.writes, 2); XCTAssertEqual(session.history.entryCount, 1)
            try session.undo(context: context)
            XCTAssertEqual(draft.recipe, before); XCTAssertEqual(binding.wrappedValue, 0.573)
            try session.redo(context: context)
            XCTAssertEqual(draft.recipe, expected); XCTAssertEqual(binding.wrappedValue, 0.549)
            XCTAssertTrue(draft.errors.isEmpty); XCTAssertNil(session.activeGesture)
        }
    }

    @MainActor func testProductionPointAndRangeBindingsPreserveNumericPrecisionAndChannel() throws {
        let (draft, session, context, controls) = try make()
        let before = draft.recipe
        let input = controls.pointRow("输入", value: 0.5, range: 0.01...0.99,
            coordinate: true, channelPath: \.rgb, index: 1).makeBinding(gesture: { nil })
        let precise = 0.5123456789
        input.wrappedValue = precise
        XCTAssertEqual(input.wrappedValue.bitPattern, precise.bitPattern, "The number-field binding must not apply slider step rounding")
        let black = controls.rangeRow("输入黑点", value: 0.1, range: 0...0.89,
            black: true, channelPath: \.red).makeBinding(gesture: { nil })
        let white = controls.rangeRow("输入白点", value: 0.9, range: 0.11...1,
            black: false, channelPath: \.red).makeBinding(gesture: { nil })
        black.wrappedValue = 0.123456789; white.wrappedValue = 0.87654321
        XCTAssertEqual(black.wrappedValue, 0.123456789); XCTAssertEqual(white.wrappedValue, 0.87654321)
        var expected = before
        expected.adjustmentsV3?.curves.rgb.curve.points[1].x = precise
        expected.adjustmentsV3?.curves.red.inputBlack = 0.123456789
        expected.adjustmentsV3?.curves.red.inputWhite = 0.87654321
        XCTAssertEqual(draft.recipe, expected); XCTAssertEqual(draft.writes, 3)
        try session.undo(context: context)
        XCTAssertEqual(white.wrappedValue, 0.9); XCTAssertEqual(black.wrappedValue, 0.123456789)
        try session.redo(context: context)
        XCTAssertEqual(white.wrappedValue, 0.87654321)
        let writes = draft.writes
        _ = try session.changePage(.filters, context: context)
        // Old views retain only their original display snapshots, not values from another scope.
        XCTAssertEqual(input.wrappedValue, 0.5); XCTAssertEqual(black.wrappedValue, 0.1); XCTAssertEqual(white.wrappedValue, 0.9)
        input.wrappedValue = 0.6
        XCTAssertEqual(draft.writes, writes); XCTAssertEqual(draft.recipe, expected)
        XCTAssertEqual(draft.errors.count, 1, "A captured binding cannot write through an obsolete interaction scope")
    }

    @MainActor func testRemovedPointFallbackIsDisplayOnlyAndDefaultRowsKeepTheirSnapshot() throws {
        let (draft, session, context, controls) = try make()
        let removed = controls.pointRow("输出", value: 1, range: 0...1,
            coordinate: false, channelPath: \.rgb, index: 2).makeBinding(gesture: { nil })
        var curves = session.parameters.curves
        curves.rgb.curve = .init()
        try session.apply(.setParameters(.curves(curves)), event: .init(context: context,
            control: .init(group: .curves, name: "remove point")))
        let before = draft.recipe, writes = draft.writes
        XCTAssertEqual(removed.wrappedValue, 1, "Missing-index fallback only keeps an old view readable during teardown")
        removed.wrappedValue = 0.6
        XCTAssertEqual(draft.recipe, before); XCTAssertEqual(draft.writes, writes); XCTAssertEqual(draft.errors.count, 1)

        let snapshot = PhotosTypedValueRow(session: session, context: context, group: .definition,
            name: "数量", value: 0.41, range: 0...2, command: { value in
                .setParameters(.definition(.init(enabled: true, amount: value)))
            }, onError: { draft.errors.append($0) }).makeBinding(gesture: { nil })
        snapshot.wrappedValue = 0.52
        XCTAssertEqual(session.parameters.definition.amount, 0.52)
        XCTAssertEqual(snapshot.wrappedValue, 0.41, "Unchanged typed rows still use their existing immutable display snapshot")
    }
}
