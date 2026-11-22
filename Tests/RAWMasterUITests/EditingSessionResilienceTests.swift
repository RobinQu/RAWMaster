import AppKit
import Metal
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMaster

/// Real renderer + real controller coverage for repeated compound edits and focus restoration.
final class EditingSessionResilienceTests: XCTestCase {
    private enum Failure: Error { case timedOut(String) }

    @MainActor private func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out: " + label)
        throw Failure.timedOut(label)
    }

    @MainActor private func prepare(_ editing: EditingController, asset: AssetRecord) async throws -> EditingInteractionContext {
        editing.isPresented = true
        editing.focus(asset)
        try await wait("real source and first frame") { editing.work != nil && editing.previews.primary.frame != nil }
        editing.beginDevelopmentInterface()
        try await wait("active development tools") { editing.developmentContext != nil }
        return try XCTUnwrap(editing.developmentContext)
    }

    @MainActor private func currentFrame(_ editing: EditingController) async throws {
        try await wait("latest compound recipe frame") {
            editing.previews.primary.frameRecipe == editing.recipe
                && editing.previews.primary.frame?.revision == editing.previews.primary.currentRevision
                && !editing.previews.primary.rendering
        }
    }

    @MainActor func testCompoundLightColorGesturesSurviveRepeatedFocusLossAndResume() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
        let backend = SharedEditingPreviewBackend(service: service)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        do {
            var context = try await prepare(editing, asset: fixture.assets[0])
            for index in 1...8 {
                let token = try editing.developmentSession.beginGesture(.init(group: .light, name: "复合曝光与颜色"), context: context)
                var light = editing.developmentSession.parameters.light
                light.enabled = true
                light.exposure = Double(index) * 0.07
                light.contrast = Double(index) * 0.015
                var color = editing.developmentSession.parameters.color
                color.enabled = true
                color.vibrance = Double(index) * 0.025
                color.saturation = Double(index) * 0.01
                let commands: [DevelopmentAdjustmentCommand] = [.setParameters(.light(light)), .setParameters(.color(color))]
                try editing.developmentSession.applyAtomically(commands,
                    title: "复合曝光与颜色", event: .init(context: context,
                        control: .init(group: .light, name: "复合曝光与颜色"),
                        nativeInput: .capture(control: "complex.light-color", phase: "change", nativeEvent: true, gestureID: token.id)), gesture: token)
                try editing.developmentSession.endGesture(token, .commit)
                try await currentFrame(editing)
                XCTAssertEqual(editing.developmentContext, context)
                XCTAssertEqual(editing.recipe.adjustmentsV3?.light.exposure, Double(index) * 0.07)
                XCTAssertEqual(editing.recipe.adjustmentsV3?.color.vibrance, Double(index) * 0.025)
            }

            for cycle in 0..<4 {
                let suspended = context
                let before = editing.recipe
                editing.suspendDevelopmentFocus()
                XCTAssertNil(editing.developmentContext)
                XCTAssertEqual(editing.developmentPresentationContext, suspended)
                XCTAssertTrue(editing.developmentToolsPaused)
                XCTAssertNotNil(editing.developmentSourceFacts)
                XCTAssertThrowsError(try editing.developmentSession.apply(.reset(.light),
                    event: .init(context: suspended, control: .init(group: .light, name: "失焦旧回调"))))
                XCTAssertEqual(editing.recipe, before)

                editing.beginDevelopmentInterface()
                try await wait("focus cycle \(cycle) restored") { editing.developmentContext != nil }
                context = try XCTUnwrap(editing.developmentContext)
                XCTAssertGreaterThan(context.draftBranchEpoch, suspended.draftBranchEpoch)
                XCTAssertEqual(editing.developmentPresentationContext, context)
                XCTAssertEqual(editing.recipe, before)

                var light = editing.developmentSession.parameters.light
                light.exposure += 0.03
                try editing.developmentSession.apply(.setParameters(.light(light)),
                    event: .init(context: context, control: .init(group: .light, name: "恢复后继续曝光")))
                try await currentFrame(editing)
                let previousExposure = try XCTUnwrap(before.adjustmentsV3?.light.exposure)
                XCTAssertEqual(editing.recipe.adjustmentsV3?.light.exposure, previousExposure + 0.03)
            }
            await editing.shutdown()
            await service.closeAll()
        } catch {
            await editing.shutdown()
            await service.closeAll()
            throw error
        }
    }
}


extension EditingSessionResilienceTests {
    @MainActor func testComplexMultiGroupRecipeRendersRoundTripsAndUndoRedoRemainExact() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
        let backend = SharedEditingPreviewBackend(service: service)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        do {
            let context = try await prepare(editing, asset: fixture.assets[0])
            let original = editing.recipe
            var light = DevelopmentLightV3(); light.enabled = true; light.exposure = 0.35; light.contrast = 0.2
            var color = DevelopmentColorV3(); color.enabled = true; color.saturation = 0.2; color.vibrance = 0.15
            let whiteBalance = DevelopmentWhiteBalanceV3(enabled: true, adjustment: .temperatureTint(temperature: 6200, tint: 8))
            var curves = DevelopmentCurvesV3(); curves.enabled = true
            curves.rgb.curve = .init(points: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.55), .init(x: 1, y: 1)])
            let handles = DevelopmentLevelsHandlesV3(black: 0.05, shadows: 0.25, midtones: 0.5,
                highlights: 0.75, white: 0.95, outputBlack: 0.01, outputWhite: 0.99)
            var levels = DevelopmentLevelsV3(); levels.enabled = true; levels.rgb = .manual(handles)
            let definition = DevelopmentDefinitionV3(enabled: true, amount: 0.4)
            var selective = DevelopmentSelectiveColorV3(); selective.enabled = true; selective.colors[0].hue = 12
            let noise = DevelopmentNoiseReductionV3(enabled: true, sourceCapability: .image, nonRawAmount: 0.4)
            let sharpen = DevelopmentSharpenV3(enabled: true, intensity: 0.3)
            let vignette = DevelopmentVignetteV3(enabled: true, strength: 0.2, radius: 0.6, softness: 0.4)
            let filter = DevelopmentFilterV3(enabled: true, selection: .vivid, intensity: 60)
            var geometry = DevelopmentGeometryV3(); geometry.straightenDegrees = 3
            geometry.crop = .init(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
            var detail = DevelopmentAdvancedDetailV3()
            detail.texture = .init(enabled: true, amount: 20); detail.clarity = .init(enabled: true, amount: 15)
            let commands: [DevelopmentAdjustmentCommand] = [
                .setParameters(.light(light)), .setParameters(.color(color)), .setParameters(.whiteBalance(whiteBalance)),
                .setParameters(.curves(curves)), .setParameters(.levels(levels)), .setParameters(.definition(definition)),
                .setParameters(.selectiveColor(selective)), .setParameters(.noiseReduction(noise)),
                .setParameters(.sharpen(sharpen)), .setParameters(.vignette(vignette)), .setParameters(.filter(filter)),
                .setParameters(.texture(detail.texture)), .setParameters(.clarity(detail.clarity)), .setGeometry(geometry)
            ]
            let token = try editing.developmentSession.beginGesture(.init(group: nil, name: "复杂多组调整"), context: context)
            try editing.developmentSession.applyAtomically(commands, title: "复杂多组调整",
                event: .init(context: context, control: .init(group: nil, name: "复杂多组调整"),
                    nativeInput: .capture(control: "complex.all-groups", phase: "change", nativeEvent: true, gestureID: token.id)), gesture: token)
            try editing.developmentSession.endGesture(token, .commit)
            try await currentFrame(editing)
            let complex = editing.recipe
            let actual = try XCTUnwrap(complex.adjustmentsV3)
            XCTAssertEqual(actual.light, light); XCTAssertEqual(actual.color, color)
            XCTAssertEqual(actual.whiteBalance, whiteBalance); XCTAssertEqual(actual.curves, curves)
            XCTAssertEqual(actual.levels, levels); XCTAssertEqual(actual.definition, definition)
            XCTAssertEqual(actual.selectiveColor, selective); XCTAssertEqual(actual.noiseReduction, noise)
            XCTAssertEqual(actual.sharpen, sharpen); XCTAssertEqual(actual.vignette, vignette)
            XCTAssertEqual(actual.filter, filter); XCTAssertEqual(actual.geometry, geometry)
            XCTAssertEqual(actual.advancedDetail.texture, detail.texture)
            XCTAssertEqual(actual.advancedDetail.clarity, detail.clarity)
            XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self, from: JSONEncoder().encode(complex)), complex)
            XCTAssertEqual(editing.developmentSession.history.entryCount, 1)
            XCTAssertEqual(editing.developmentContext, context)
            XCTAssertNil(editing.message)

            editing.undoDevelopment(context: context)
            XCTAssertEqual(editing.recipe, original)
            try await currentFrame(editing)
            editing.undoDevelopment(context: context, redo: true)
            XCTAssertEqual(editing.recipe, complex)
            try await currentFrame(editing)
            try editing.developmentSession.apply(.resetAll,
                event: .init(context: context, control: .init(group: nil, name: "复位复杂调整")))
            XCTAssertEqual(editing.recipe.adjustmentsV3, DevelopmentAdjustmentsV3())
            try await currentFrame(editing)
            await editing.shutdown(); await service.closeAll()
        } catch {
            await editing.shutdown(); await service.closeAll(); throw error
        }
    }
}
