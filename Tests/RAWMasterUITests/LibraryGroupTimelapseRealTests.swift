import Foundation
import AVFoundation
import RAWMasterCore
import RAWMasterLibrary
import XCTest
@testable import RAWMaster

final class LibraryGroupTimelapseRealTests: XCTestCase {
    @MainActor func testPublishedTimelapseSurvivesExternalExportRemoval() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_RUNTIME_RAW_DIRECTORY"] else { throw XCTSkip("需要实拍 RAW 组") }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("library-group-" + UUID().uuidString)
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:directory) }
        let catalog = directory.appendingPathComponent("library.sqlite")
        let store = try LibraryStore(databaseURL:catalog)
        let session = try await ImportService(store:store).importDirectory(source:URL(fileURLWithPath:path),destination:nil,
            projectName:"延时回归",mode:.reference,progress:{ _ in })
        let frames = try store.loadAssets(sessionID:session.id).sorted { $0.filename < $1.filename }
        XCTAssertEqual(frames.count,6)
        try store.createGroup(ids:frames.map(\.id),name:"实拍延时",kind:"延时")
        let group = try XCTUnwrap(store.loadGroups().first)
        let input = try TimelapseInput.make(group:group,eligibleAssets:frames)
        let external = directory.appendingPathComponent("export.mp4")
        var recipe = TimelapseSettings()
        recipe.frameRate = 24
        let result = try await LibraryGroupRendering.export(actions:store.catalogActions,input:input,settings:recipe,
                                                           destination:external,progress:{ _ in })
        XCTAssertEqual(result.frameCount,6)
        let externalData = try Data(contentsOf:external)
        try fm.removeItem(at:external)
        let jobs = try await store.catalogActions.read("groupProcessing",["action":.string("list"),"groupID":.string(group.id)])
        let items = try XCTUnwrap(jobs["jobs"]?.arrayValue)
        let job = try XCTUnwrap(items.first)
        let id = try XCTUnwrap(job["jobID"]?.stringValue)
        let staged = try await store.catalogActions.read("groupProcessing",["action":.string("inspectOutput"),"jobID":.string(id)])
        let master = try XCTUnwrap(staged["path"]?.stringValue)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:master)),externalData)
        let byFile = try await store.catalogActions.read("groupProcessing",["action":.string("list"),"fileID":.string(frames[0].id)])
        XCTAssertTrue((byFile["jobs"]?.arrayValue ?? []).contains { $0["jobID"]?.stringValue == id })
        let db = try LibraryStore(databaseURL:catalog)
        let reopened = try await db.catalogActions.read("groupProcessing",["action":.string("inspectOutput"),"jobID":.string(id)])
        XCTAssertEqual(reopened["path"],staged["path"])
        let workID = try XCTUnwrap(reopened["workID"]?.stringValue)
        let reopenedMedia = await CatalogWorkMedia.resolve(workID, actions:db.catalogActions)
        let clip = try XCTUnwrap(reopenedMedia)
        let tracks = try await clip.videoAsset().loadTracks(withMediaType:.video)
        XCTAssertEqual(tracks.count, 1)
        let image = try await AVAssetImageGenerator(asset:clip.videoAsset()).image(at:.zero).image
        XCTAssertGreaterThan(image.width, 0)

    }
}
