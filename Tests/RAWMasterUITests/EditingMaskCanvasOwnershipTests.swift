import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

private actor DelayedMaskReply {
    private var continuation: CheckedContinuation<Void, Never>?
    var isPending: Bool { continuation != nil }

    func suspend() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func deliver() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class MountedMaskCanvas: ObservableObject {
    typealias Owner = EditingMaskInputSession.CanvasOwner
    @Published var mounted: Owner?
    var appearances = Set<Owner>()
    var disappearances = Set<Owner>()
}

@MainActor private struct DelayedMaskCanvasHost: View {
    @ObservedObject var mount: MountedMaskCanvas
    let editing: EditingController
    let input: EditingMaskInputSession
    @State private var transform = ImageTransform()

    var body: some View {
        ZStack {
            Color.black
            if let owner = mount.mounted {
                PhotosMaskEditingCanvas(editing: editing, input: input, owner: owner, transform: $transform)
                    .id(owner)
                    .onAppear { mount.appearances.insert(owner) }
                    .onDisappear { mount.disappearances.insert(owner) }
            }
        }
    }
}

@MainActor final class EditingMaskCanvasOwnershipTests: XCTestCase {
    private func waitFor(_ label: String, _ ready: () -> Bool) async throws {
        for _ in 0..<1000 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "EditingMaskCanvasOwnershipTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for " + label])
    }

    private func open(_ model: AppModel, asset: AssetRecord) async throws -> (EditingController, EditingInteractionContext) {
        model.selectScope(.project, id: asset.projectID)
        model.select(asset)
        model.setMode(.single)
        model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await waitFor("active editor") {
            if editing.work != nil && editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil
        }
        return (editing, try XCTUnwrap(editing.developmentContext))
    }

    func testDelayedDepartureOfPreviousCanvasCannotCancelNextRequestInSameContext() async throws {
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let (editing, context) = try await open(model, asset: fixture.assets[0])
        let gate = DelayedMaskReply()
        defer { Task { await gate.deliver() } }
        let png = try DevelopmentMaskBitmap(width: 4, height: 4, values: Array(repeating: 200, count: 16)).png()
        let input = EditingMaskInputSession(editing: editing) { _, source, target, _ in
            if target == .background { await gate.suspend() }
            let snapshot = DevelopmentSemanticMaskSnapshot(source: source, target: target, generator: "fixture", width: 4, height: 4, png: png)
            return try DevelopmentMaskCandidate(layer: .init(kind: .subject, subjectPNG: png, semanticSnapshot: snapshot), source: source)
        }
        editing.developmentMaskInput = input
        let mount = MountedMaskCanvas()
        let window = NSWindow(contentRect: .init(x: -4000, y: 0, width: 360, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DelayedMaskCanvasHost(mount: mount, editing: editing, input: input))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }

        let original = editing.recipe
        input.begin(.subject, context: context)
        try await waitFor("first candidate") { input.canAdopt }
        let first = try XCTUnwrap(input.canvasOwner)
        mount.mounted = first
        try await waitFor("first visible canvas") { mount.appearances.contains(first) }

        // SwiftUI can remove the old view after the next request has already begun.
        input.cancel()
        input.begin(.background, context: context)
        for _ in 0..<300 {
            if await gate.isPending { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await gate.isPending
        XCTAssertTrue(pending)
        XCTAssertTrue(input.busy)
        mount.mounted = nil
        try await waitFor("outgoing canvas onDisappear") { mount.disappearances.contains(first) }
        XCTAssertTrue(input.busy)
        XCTAssertNil(input.candidate)

        await gate.deliver()
        try await waitFor("second candidate") { input.canAdopt }
        let second = try XCTUnwrap(input.canvasOwner)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.context, second.context)
        XCTAssertEqual(input.candidate?.target, .background)
        mount.mounted = second
        try await waitFor("second visible canvas") { mount.appearances.contains(second) }
        mount.mounted = nil
        try await waitFor("current canvas cancellation") { mount.disappearances.contains(second) && !input.isActive }
        XCTAssertNil(input.candidate)
        XCTAssertEqual(editing.recipe, original)
        XCTAssertFalse(editing.developmentSession.canUndo)
        await editing.shutdown()
    }

    func testCountersObserveTheEditorsGeneratorAndExcludeBrushesAndFailures() async throws {
        guard let folder = ProcessInfo.processInfo.environment["RAWMASTER_MASK_FIXTURES"] else {
            throw XCTSkip("Set RAWMASTER_MASK_FIXTURES for the photographic Vision input.")
        }
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let original = URL(fileURLWithPath: folder).appending(path: "person.ARW")
        let inputFile = try XCTUnwrap(CGImageSourceCreateWithURL(original as CFURL, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(inputFile, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ] as CFDictionary))
        let photo = fixture.root.appending(path: "person.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, thumbnail, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let asset = try fixture.store.register(.init(sessionID: fixture.assets[0].sessionID, projectID: fixture.assets[0].projectID,
            sourcePath: photo.path, fileSize: Int64(try Data(contentsOf: photo).count), importState: .ready))
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let (editing, context) = try await open(model, asset: asset)
        let input = editing.developmentMaskInput
        func counts(_ hits: Int, _ generated: Int, line: UInt = #line) async {
            let actual = await input.candidateCounts()
            XCTAssertEqual(actual.exactCacheHits, hits, line: line)
            XCTAssertEqual(actual.successfulGenerations, generated, line: line)
        }
        await counts(0, 0)
        input.begin(.brush, context: context)
        try await waitFor("manual brush") { input.candidate?.target == .brush }
        await counts(0, 0)
        input.begin(.subject, context: context)
        try await waitFor("system Vision result") { input.canAdopt || input.note != nil }
        XCTAssertNil(input.note)
        await counts(0, 1)
        input.cancel()
        input.begin(.subject, context: context)
        try await waitFor("identical subject result") { input.canAdopt || input.note != nil }
        XCTAssertEqual(input.candidate?.target, .subject)
        await counts(1, 1)
        let source = try XCTUnwrap(editing.developmentSession.source)
        let cancelled = Task {
            try? await Task.sleep(for: .seconds(3))
            return try await input.presetCandidate(capture: photo, source: source, target: .background)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled request returned coverage.")
        } catch {}
        await counts(1, 1)
        var wrong = source
        wrong.sourceContentID = String(repeating: "0", count: 64)
        do {
            _ = try await input.presetCandidate(capture: photo, source: wrong, target: .subject)
            XCTFail("A foreign source was accepted.")
        } catch { XCTAssertEqual(error as? DevelopmentMaskError, .staleSource) }
        await counts(1, 1)
        await editing.shutdown()
    }
}
