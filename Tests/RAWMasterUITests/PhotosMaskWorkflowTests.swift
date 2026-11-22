import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosMaskWorkflowTests:XCTestCase{
    func testVectorscopeRotatesStandardChromaAxesTogether() {
        let red = PhotosVectorscopeOrientation.angle(hue: 0, redAtThree: false)
        XCTAssertEqual(red * 180 / .pi, 102.91, accuracy: 0.1)
        XCTAssertEqual(PhotosVectorscopeOrientation.angle(hue: 0, redAtThree: true), 0, accuracy: 1e-10)
        for i in 1..<12 {
            let hue = Double(i) / 12
            let native = PhotosVectorscopeOrientation.angle(hue: hue, redAtThree: false)
            XCTAssertEqual(PhotosVectorscopeOrientation.angle(hue: hue, redAtThree: true), native - red, accuracy: 1e-10)
        }
    }
    @MainActor func testMaskLayerIsLivePersistentAndUndoable()async throws{
        let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
        let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
        model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
        let editing=try XCTUnwrap(model.editing)
        for _ in 0..<500 where editing.developmentContext == nil{
            if editing.work != nil{editing.beginDevelopmentInterface()}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let context=try XCTUnwrap(editing.developmentContext)
        editing.addDevelopmentMask(.range,context:context)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.masks.count,1)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.masks[0].kind,.range)
        let maskID = try XCTUnwrap(editing.recipe.adjustmentsV3?.masks.first?.id)
        editing.selectDevelopmentScopeMask(maskID)
        XCTAssertEqual(editing.visibleScopeMaskID, maskID)
        editing.undoDevelopment(context:context)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.masks.count ?? 0,0)
        XCTAssertNil(editing.visibleScopeMaskID)
        editing.undoDevelopment(context:context,redo:true)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.masks.count,1)
        await editing.shutdown()
        let store=try LibraryStore(databaseURL:fixture.library)
        let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
        XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.masks.count,1)
    }
    @MainActor func testMaskCurvesPersistAndUndo()async throws{
        let fixture=try EditingWorkflowTests.Fixture();defer{fixture.clean()}
        let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
        model.selectScope(.project,id:fixture.assets[0].projectID);model.select(fixture.assets[0]);model.setMode(.single);model.openNativeEditing()
        let editing=try XCTUnwrap(model.editing)
        for _ in 0..<500 where editing.developmentContext == nil{
            if editing.work != nil{editing.beginDevelopmentInterface()}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let context=try XCTUnwrap(editing.developmentContext)
        editing.addDevelopmentMask(.range,context:context)
        var layer=try XCTUnwrap(editing.recipe.adjustmentsV3?.masks[0])
        layer.adjustments.curves = .init(enabled:true,rgb:.init(curve:.init(points:[.init(x:0,y:0),.init(x:0.25,y:0.4),.init(x:1,y:1)])))
        layer.adjustments.grading = .init(shadows:.init(hueDegrees:30,saturation:35,luminance:8),midtones:.init(hueDegrees:200,saturation:20),blending:60,balance:20)
        layer.adjustments.sharpness=0.25;layer.adjustments.noiseReduction=0.2;layer.adjustments.moireReduction=0.3;layer.adjustments.defringe = -1
        layer.adjustments.dehaze = -0.35
        try editing.developmentSession.apply(.setMasks([layer]),event:.init(context:context,control:.init(group:nil,name:"局部曲线与分级")))
        XCTAssertEqual(editing.recipe.adjustmentsV3?.masks[0].adjustments,layer.adjustments)
        editing.undoDevelopment(context:context)
        XCTAssertNil(editing.recipe.adjustmentsV3?.masks[0].adjustments.curves)
        XCTAssertNil(editing.recipe.adjustmentsV3?.masks[0].adjustments.grading)
        XCTAssertNil(editing.recipe.adjustmentsV3?.masks[0].adjustments.defringe)
        XCTAssertNil(editing.recipe.adjustmentsV3?.masks[0].adjustments.dehaze)
        editing.undoDevelopment(context:context,redo:true)
        XCTAssertEqual(editing.recipe.adjustmentsV3?.masks[0].adjustments,layer.adjustments)
        await editing.shutdown()
        let store=try LibraryStore(databaseURL:fixture.library)
        let work=try XCTUnwrap(store.loadPhotoWorks(assetID:fixture.assets[0].id).first)
        XCTAssertEqual(work.liveRecipe?.adjustmentsV3?.masks[0].adjustments,layer.adjustments)
    }
}
