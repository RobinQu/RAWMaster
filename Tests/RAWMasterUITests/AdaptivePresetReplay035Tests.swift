import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

extension EditingInteractionPerformanceTests {
    @MainActor func testOptIn035AdaptiveSubjectReplaysTwoRealRAWs() async throws {
        try await replayAdaptivePreset(.subject)
    }

    @MainActor func testOptIn035AdaptiveSkyReplaysTwoRealRAWs() async throws {
        try await replayAdaptivePreset(.sky)
    }

    private func requireAdaptive(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeFailure(message) }
    }

    @MainActor private func replayAdaptivePreset(_ target: DevelopmentSemanticTarget) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAWMASTER_035_ADAPTIVE"] == "1" else { throw XCTSkip("Enable the 035 real RAW adaptive replay") }
        #if DEBUG
        throw ProbeFailure("Use the Release test bundle for real RAW adaptive replay")
        #else
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = URL(fileURLWithPath: try Self.required(env["RAWMASTER_MASK_FIXTURES"], "Set RAWMASTER_MASK_FIXTURES"))
        let raw = env["RAWMASTER_035_RAW_ROOT"].map { URL(fileURLWithPath: $0) } ?? root.appending(path: "experiments/MaskAI/Fixtures/RAW")
        let models = URL(fileURLWithPath: try Self.required(env["RAWMASTER_MASK_PACK"], "Set RAWMASTER_MASK_PACK"))
        let out = URL(fileURLWithPath: try Self.required(env["RAWMASTER_035_ADAPTIVE_OUTPUT"], "Set RAWMASTER_035_ADAPTIVE_OUTPUT"))
            .appending(path: target.rawValue)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let common = (raw.appending(path: "sony-landscape.ARW"), "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c")
        let second = target == .subject
            ? (fixtures.appending(path: "person.ARW"), "0a0775e6f803329341b954fd4d0ed08d6cc71b3b226c34d0218865761e31f0d8")
            : (raw.appending(path: "sony-sample-02.ARW"), "4e7e80f4e34e3f9d2b77c93c4c0864fb2a8b950df69e615b5e99b7bad6a9739f")
        let xmpHash = target == .subject ? "c21d5229b88db9cce13c58c47fbe9f44980753a601a5f7897b91f3ce47eb7f6d"
                                         : "055748f89e720487be706f9c501962b1dde87d9f5181c24f5bd4c07a6883bfcd"
        let catalog = DevelopmentPresetCatalog(root: out.appending(path: "catalog"))
        let stage = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: root.appending(path:
            "specs/031-preset-browser/contracts/migration-manifest-v1.json"), catalog: catalog)
        try requireAdaptive(stage.frozenMigrationReady, "031 frozen migration input changed or is unavailable")
        _ = try stage.commit(to: catalog)
        let imported = try Self.required(try catalog.records().first { $0.sourceSHA256 == xmpHash })
        let originalBytes = try catalog.originalData(sha256: xmpHash)
        try requireAdaptive(DevelopmentSemanticMaskSnapshot.digest(originalBytes) == xmpHash, "Different source XMP")
        let record = try DevelopmentPresetExchange.semanticReconstruction(for: imported)
        try requireAdaptive(record.patch.semanticMasks?.map(\.target) == [target], "Unexpected XMP local correction")
        _ = NSApplication.shared
        let library = out.appending(path: "library.sqlite")
        let defaultsName = "RAWMaster035-" + UUID().uuidString
        let defaults = try Self.required(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var prior: DevelopmentMaskLayerV3?
        var receipts: [[String: Any]] = []
        for (url, sha) in [common, second] {
            let source = url.resolvingSymlinksInPath()
            let dir = out.appending(path: String(sha.prefix(12)))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let asset = try await Task.detached {
                let store = try LibraryStore(databaseURL: library)
                let project = ProjectRecord(name: "035 real Adaptive preset")
                try store.saveProject(project)
                let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: source.deletingLastPathComponent().path,
                    mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
                try store.saveSession(session)
                guard try FileSafety.hash(source) == sha else { throw ProbeFailure("RAW SHA differs: " + source.lastPathComponent) }
                let reader = try Self.required(CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
                let properties = try Self.required(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any])
                let asset = try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name, sourcePath: source.path,
                    currentPath: source.path, filename: source.lastPathComponent, fileSize: try FileSafety.stat(source).size,
                    width: properties[kCGImagePropertyPixelWidth as String] as? Int, height: properties[kCGImagePropertyPixelHeight as String] as? Int,
                    contentHash: sha, importState: .ready))
                try store.completedDirectImport(session)
                return asset
            }.value
            var photo: [String: Any] = ["sourceSHA256": sha, "presetSHA256": xmpHash]
            let prepared = try await withAdaptiveEditor(asset: asset, library: library, defaults: defaults, models: models) { editing, context in
                let session = editing.developmentSession
                let binding = try Self.required(session.source)
                let decoder = try Self.required(session.parameters.rawDecoder)
                try self.requireAdaptive(binding.sourceContentID == sha && decoder == .flashRaw031, "Source or decoder changed")
                let before = session.recipe, history = session.history.entryCount
                let ticket = DevelopmentPresetMaskPreparation.Ticket(record: record, context: context, revision: session.revision)
                if let prior {
                    do {
                        _ = try session.adoptPreset(record, context: context, revision: ticket.revision, preparedMasks: [prior])
                        throw ProbeFailure("Previous photo's frozen coverage was accepted")
                    } catch DevelopmentPresetError.needsPreparation {}
                }
                let preparation = DevelopmentPresetMaskPreparation()
                defer { preparation.cancel() }
                preparation.start(ticket, source: binding, existingLayerCount: session.parameters.masks.count,
                    isCurrent: { editing.developmentContext == context && session.revision == ticket.revision },
                    generate: { target in
                        let candidate = try await editing.developmentMaskInput.presetCandidate(capture: source, source: binding, target: target)
                        return try await Task.detached { try candidate.layer() }.value
                    })
                try await self.wait("real local target " + target.rawValue, seconds: 120) { !preparation.busy }
                let layers = try Self.required(preparation.layers(for: ticket), preparation.status)
                let layer = try Self.required(layers.first)
                let snapshot = try Self.required(layer.semanticSnapshot)
                try snapshot.validate(png: Self.required(layer.subjectPNG))
                try self.requireAdaptive(session.history.entryCount == history && session.recipe == before &&
                    snapshot.source == binding && snapshot.target == target && !snapshot.wasRefined && snapshot.prompt.isEmpty,
                    "Preparation changed the draft or lost its source binding")
                let stats = try Self.required(await editing.developmentMaskInput.analysisDiagnostics(for: sha))
                try self.requireAdaptive(stats.successfulGenerations == 1 && stats.exactCacheHits == 0 && stats.flashRawDecodes == 1 &&
                    (target == .subject ? stats.visionRequests : stats.landscapeRuns) > 0 && stats.modelInvocations > 0,
                    "Missing fresh inference or selected decoder")
                if target == .sky {
                    try self.requireAdaptive(snapshot.modelHashes.contains(DevelopmentMaskModelPack.landscapeHash), "Missing landscape model identity")
                }
                try self.requireAdaptive(try session.adoptPreset(record, context: context, revision: ticket.revision, preparedMasks: layers),
                    "Reconstructed preset did not commit")
                let adoption = try Self.required(session.presetAdoptions.last)
                try self.requireAdaptive(session.history.entryCount == history + 1 && adoption.presetID == imported.id &&
                    adoption.sourceSHA256 == xmpHash && adoption.sourceID == sha && adoption.policy == "reconstructed" &&
                    adoption.assetHashes.contains(snapshot.pngSHA256), "Adoption lost the XMP or image-specific frozen mask")
                _ = try await self.drawn(editing, recipe: session.recipe, quality: .settled, label: "adaptive preset committed")
                photo["analysis"] = Self.maskDiagnostics(stats)
                photo["pngSHA256"] = snapshot.pngSHA256
                photo["modelHashes"] = snapshot.modelHashes
                photo["recipeSHA256"] = try EditingFingerprint.of(session.recipe)
                return (layer, context.workID, adoption)
            }
            try requireAdaptive(prior == nil || (prior?.id != prepared.0.id && prior?.semanticSnapshot?.pngSHA256 != prepared.0.semanticSnapshot?.pngSHA256),
                "Two distinct photos share frozen coverage")
            prior = prepared.0
            // The new controller has an empty optional model directory. The real frozen snapshot must suffice.
            _ = try await withAdaptiveEditor(asset: asset, library: library, defaults: defaults, models: dir.appending(path: "offline-pack")) { editing, context in
                let reopened = editing.developmentSession
                try self.requireAdaptive(context.workID == prepared.1 && reopened.parameters.masks.contains(prepared.0) &&
                    reopened.presetAdoptions.contains(prepared.2), "Reopened draft or adoption differs")
                _ = try await self.drawn(editing, recipe: reopened.recipe, quality: .settled, label: "offline adaptive reopen")
                let atDraw = await editing.developmentMaskInput.analysisDiagnostics(for: sha)?.modelInvocations ?? 0
                try await Self.exportReopenedMask(library: library, workID: context.workID, layer: prepared.0,
                    output: dir, report: &photo, expectsBrighter: false)
                let afterExport = await editing.developmentMaskInput.analysisDiagnostics(for: sha)?.modelInvocations ?? 0
                let gates = try Self.required(photo["gates"] as? [String: Bool])
                try self.requireAdaptive(atDraw == 0 && afterExport == 0 && gates.values.allSatisfy { $0 },
                    "Reopen/export reinferred or a TIFF16 pixel gate failed: " + String(describing: gates))
                photo["modelInvocationsAtReopenedDraw"] = atDraw
                photo["modelInvocationsAfterExport"] = afterExport
            }
            let after = try FileSafety.hash(source)
            try requireAdaptive(after == sha, "Source changed during replay")
            photo["sourceSHA256After"] = after
            try JSONSerialization.data(withJSONObject: photo, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "receipt.json"))
            receipts.append(photo)
        }
        let binary = try Self.required(Bundle(for: EditingInteractionPerformanceTests.self).executableURL)
        let result: [String: Any] = ["status": "passed", "build": "release", "testBinarySHA256": try FileSafety.hash(binary),
            "target": target.rawValue, "preset": record.name, "sourceXmpSHA256": xmpHash,
            "crossPhotoAdoptionRejected": true, "photos": receipts]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "receipt.json"))
        #endif
    }

    @MainActor private func withAdaptiveEditor<T>(asset: AssetRecord, library: URL, defaults: UserDefaults, models: URL,
        run: (EditingController, EditingInteractionContext) async throws -> T) async throws -> T {
        let model = AppModel(libraryURL: library, defaults: defaults)
        let editing = try Self.required(model.editing, model.errorMessage ?? "AppModel has no editor")
        editing.developmentMaskInput = EditingMaskInputSession(editing: editing, pack: .init(root: models))
        let host = NSHostingView(rootView: EditingImageCanvas(editing: editing).environmentObject(model))
        let window = NSWindow(contentRect: .init(x: 20, y: 20, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await wait("real adaptive RAW frame", seconds: 90) { editing.work != nil && editing.previews.primary.frame != nil }
            editing.beginDevelopmentInterface()
            try await wait("real adaptive editing context") { editing.developmentContext != nil }
            let context = try Self.required(editing.developmentContext)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let value = try await run(editing, context)
            await editing.shutdown()
            return value
        } catch {
            await editing.shutdown()
            throw error
        }
    }
}
