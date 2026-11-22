import XCTest
@testable import RAWMaster
@testable import RAWMasterImaging
import RAWMasterCore

private actor MaskCompletionGate {
    private var waiter: CheckedContinuation<Void,Never>?
    var ready: Bool { waiter != nil }
    func hold() async { await withCheckedContinuation { waiter = $0 } }
    func finish() { waiter?.resume(); waiter = nil }
}

@MainActor final class PhotosSemanticMaskInteractionTests: XCTestCase {
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("Timed out waiting for edit pane",file:file,line:line)
    }
    private func open(_ f: EditingWorkflowTests.Fixture) async throws -> (AppModel,EditingController,EditingInteractionContext) {
        let model = AppModel(libraryURL:f.library,defaults:f.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
        model.selectScope(.project,id:f.assets[0].projectID); model.select(f.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait {
            if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil
        }
        return (model,editing,try XCTUnwrap(editing.developmentContext))
    }

    func testPaintReviewAdoptUndoAndReopenFromProject() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let (model,editing,context) = try await open(f); _ = model
        let input = editing.developmentMaskInput
        input.begin(.brush,context:context)
        try await wait { input.candidate != nil || input.note != nil }
        XCTAssertNil(input.note)
        let size = try XCTUnwrap(input.candidate?.bitmap)
        XCTAssertEqual(size.width,120); XCTAssertEqual(size.height,80)
        XCTAssertFalse(input.canAdopt); XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        try await wait {
            if let f = editing.previews.primary.frame {
                _ = editing.previews.primary.didDraw(.init(frameID:f.id,drawBeganUptimeNanoseconds:1,drawReturnedUptimeNanoseconds:2,imagePixelWidth:120,imagePixelHeight:80))
            }
            return editing.developmentLocalFrame(context:context) != nil
        }
        func stroke(_ phase: ImageCanvasPointerPhase, id: UUID, frame: UUID, x: Double, y: Double) {
            let view = ImageCanvasViewportSnapshot(frameID:frame,viewportSize:.init(width:120,height:80),imagePixelSize:.init(width:120,height:80),
                                                   imageRect:.init(x:0,y:0,width:120,height:80),backingScale:1,transform:.init())
            XCTAssertTrue(input.pointer(.init(phase:phase,gestureID:id,beganFrameID:frame,viewport:view,locationInView:.init(x:x,y:y),
                                              pressure:1,supportsPressure:false,modifiersRawValue:0,eventTimestamp:1),context:context))
        }
        let fr = try XCTUnwrap(editing.developmentLocalFrame(context:context)).frameID
        let g = UUID()
        stroke(.began,id:g,frame:fr,x:25,y:20); stroke(.ended,id:g,frame:fr,x:50,y:20)
        XCTAssertTrue(input.canAdopt)
        XCTAssertEqual(input.candidate?.bitmap.values[20*120+30],255)
        XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        input.adopt(context:context)
        let layer = try XCTUnwrap(editing.developmentSession.parameters.masks.first)
        XCTAssertEqual(layer.semanticSnapshot?.target,.brush); XCTAssertEqual(editing.developmentScopeMaskID,layer.id)
        input.review(layer,context:context)
        XCTAssertEqual(input.candidate?.bitmap.values[20*120+30],255)
        input.cancel()
        editing.undoDevelopment(context:context); XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        editing.undoDevelopment(context:context,redo:true); XCTAssertEqual(editing.developmentSession.parameters.masks,[layer])
        await editing.shutdown()
        let disk = try LibraryStore(databaseURL:f.library)
        let persisted = try XCTUnwrap(disk.loadPhotoWorks(assetID:f.assets[0].id).first?.liveRecipe?.adjustmentsV3?.masks.first)
        XCTAssertEqual(try DevelopmentMaskBitmap(layer:persisted).values[20*120+30],255)
    }

    func testOriginalHoldAndComparisonOwnCanvasAcrossLateResultsAndRestoration() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let (model,editing,context) = try await open(f); _ = model
        let gate = MaskCompletionGate()
        let png = try DevelopmentMaskBitmap(width:4,height:4,values:Array(repeating:210,count:16)).png()
        let input = EditingMaskInputSession(editing:editing) { _,source,_,_ in
            await gate.hold()
            let snapshot = DevelopmentSemanticMaskSnapshot(source:source,target:.subject,generator:"fixture",width:4,height:4,png:png)
            return try DevelopmentMaskCandidate(layer:.init(kind:.subject,subjectPNG:png,semanticSnapshot:snapshot),source:source)
        }
        editing.developmentMaskInput = input
        let prior = editing.recipe, undo = editing.developmentSession.canUndo
        for key in ["v","m"] {
            for finishFirst in [true,false] {
                input.begin(.subject,context:context)
                for _ in 0..<200 { if await gate.ready { break }; try await Task.sleep(for:.milliseconds(5)) }
                let ready = await gate.ready; XCTAssertTrue(ready)
                if finishFirst { await gate.finish(); try await wait { input.canAdopt } }
                let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:1,
                    windowNumber:0,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:key == "v" ? 9 : 46))
                XCTAssertTrue(editing.handleDevelopmentKey(event))
                XCTAssertTrue(key == "v" ? editing.comparing : editing.developmentShowingOriginal)
                XCTAssertFalse(input.usesCanvas); XCTAssertFalse(input.busy); XCTAssertFalse(input.allowsInput(context))
                input.begin(.subject,context:context); input.adopt(context:context)
                XCTAssertFalse(input.isActive)
                if key == "v" { XCTAssertTrue(editing.handleDevelopmentKey(event)) }
                else { editing.setDevelopmentOriginalHeld(false) }
                if !finishFirst {
                    await gate.finish()
                    await Task.yield(); await Task.yield()
                }
                XCTAssertTrue(input.allowsInput(context)); XCTAssertNil(input.candidate)
                XCTAssertFalse(input.canAdopt); XCTAssertEqual(editing.recipe,prior); XCTAssertEqual(editing.developmentSession.canUndo,undo)
            }
        }
        await editing.shutdown()
    }

    func testCancelFromMaskPanelReachesModelInstaller() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let (model,editing,_) = try await open(f); _ = model
        let started = expectation(description:"installation started"), cancelled = expectation(description:"worker received cancellation")
        let input = EditingMaskInputSession(editing:editing,pack:.init(root:f.root.appending(path:"models")),install:{ _,_ in
            started.fulfill()
            do { try await Task.sleep(for:.seconds(10)) }
            catch is CancellationError { cancelled.fulfill(); throw CancellationError() }
        })
        editing.developmentMaskInput = input
        input.install(.landscape,folder:f.root)
        await fulfillment(of:[started],timeout:2)
        XCTAssertTrue(input.busy); input.cancel(); await fulfillment(of:[cancelled],timeout:2)
        XCTAssertNil(input.note); XCTAssertFalse(input.busy)
        await editing.shutdown()
    }

    func testLateCompletionAfterCancelRevisionOrPhotoSwitchCannotPublish() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let (model,editing,context) = try await open(f)
        let gate = MaskCompletionGate()
        let data = try DevelopmentMaskBitmap(width:4,height:4,values:[UInt8](repeating:200,count:16)).png()
        let input = EditingMaskInputSession(editing:editing) { _,source,_,_ in
            await gate.hold()
            let snapshot = DevelopmentSemanticMaskSnapshot(source:source,target:.subject,generator:"fixture",width:4,height:4,png:data)
            let layer = DevelopmentMaskLayerV3(kind:.subject,subjectPNG:data,semanticSnapshot:snapshot)
            return try DevelopmentMaskCandidate(layer:layer,source:source)
        }
        for change in 0..<3 {
            input.begin(.subject,context:context)
            for _ in 0..<200 { if await gate.ready { break }; try await Task.sleep(nanoseconds:5_000_000) }
            let ready = await gate.ready; XCTAssertTrue(ready)
            switch change {
            case 0: input.cancel()
            case 1: editing.addDevelopmentMask(.range,context:context)
            default: model.select(f.assets[1]); editing.focus(f.assets[1])
            }
            await gate.finish()
            try await wait { !input.busy }
            XCTAssertNil(input.candidate); XCTAssertFalse(input.canAdopt)
            XCTAssertFalse(editing.developmentSession.parameters.masks.contains { $0.kind == .subject })
        }
        await editing.shutdown()
    }
}
