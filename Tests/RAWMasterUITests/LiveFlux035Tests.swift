import AppKit
import Combine
import ImageIO
import SwiftUI
import XCTest
import RAWMasterAI
@testable import RAWMasterCore
@testable import RAWMasterImaging
import RAWMasterLibrary
@testable import RAWMaster

extension EditingInteractionPerformanceTests {
    private struct MixedDelivery: Sendable {
        let model: AppModel
        let store: LibraryStore
        let assets: Set<String>
        let intake: URL
        let intakeCount: Int
        let destination: URL
        let fixtureSHA256: String
    }

    private final class MixedTimeline: @unchecked Sendable {
        private let lock = NSLock()
        private var timestamps: [String: UInt64] = [:]

        func mark(_ event: String) {
            lock.withLock { timestamps[event] = timestamps[event] ?? DispatchTime.now().uptimeNanoseconds }
        }

        var events: [String: UInt64] { lock.withLock { timestamps } }
    }

    @MainActor func testOptIn035SkyMaskWithConcurrentWorkbenchAndIntake() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let location = env["RAWMASTER_035_MIXED_MASK_OUTPUT"] else {
            throw XCTSkip("Set a fresh output directory for the real mixed mask workload")
        }
        #if DEBUG
        throw ProbeFailure("Use the Release test bundle for real mixed-workload timing")
        #else
        let out = URL(fileURLWithPath: location, isDirectory: true)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rawRoot = env["RAWMASTER_035_RAW_ROOT"].map { URL(fileURLWithPath: $0) } ?? repo.appending(path: "experiments/MaskAI/Fixtures/RAW")
        let pack = URL(fileURLWithPath: try Self.required(env["RAWMASTER_MASK_PACK"], "Set the installed semantic mask pack"))
        let foreground = repo.appending(path: "specs/030-ai-retouching/evidence/mountain-lake.jpg")
        let sky = rawRoot.appending(path: "sony-landscape.ARW").resolvingSymlinksInPath()
        let foregroundSHA = "503aa25139ab5cabccdc919c4e76643b97e51cf202643766d9606ad36406c442"
        let skySHA = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
        let suite = "RAWMaster035-MixedMask-" + UUID().uuidString
        let defaults = try Self.required(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let mixed = try Self.required(try await prepareMixedDelivery(root: out, defaults: defaults), "Set the frozen mixed delivery input root")
        let photoDB = out.appending(path: "canvas/library.sqlite")
        let skyDB = out.appending(path: "mask/library.sqlite")
        let photoAsset = try Self.registerBenchmarkPhoto(foreground, database: photoDB, sha256: foregroundSHA, projectName: "035 exposure canvas")
        let skyAsset = try Self.registerBenchmarkPhoto(sky, database: skyDB, sha256: skySHA, projectName: "035 sky segmentation")
        let photoModel = AppModel(libraryURL: photoDB, defaults: defaults)
        let maskModel = AppModel(libraryURL: skyDB, defaults: defaults)
        let canvas = try Self.required(photoModel.editing)
        let maskEditor = try Self.required(maskModel.editing)
        maskEditor.developmentMaskInput = EditingMaskInputSession(editing: maskEditor, pack: .init(root: pack))
        let host = NSHostingView(rootView: EditingImageCanvas(editing: canvas).environmentObject(photoModel))
        let window = NSWindow(contentRect: .init(x: 20, y: 20, width: 1024, height: 768), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        do {
            canvas.isPresented = true
            canvas.focus(photoAsset)
            maskEditor.isPresented = true
            maskEditor.focus(skyAsset)
            try await wait("separate foreground and mask originals", seconds: 90) {
                canvas.sourceReady && canvas.previews.primary.frame != nil &&
                    maskEditor.sourceReady && maskEditor.previews.primary.frame != nil
            }
            canvas.beginDevelopmentInterface()
            maskEditor.beginDevelopmentInterface()
            try await wait("native exposure and mask editing contexts") {
                canvas.developmentContext != nil && maskEditor.developmentContext != nil
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = try await drawn(canvas, recipe: canvas.recipe, quality: .settled, label: "exposure warm-up")
            let context = try Self.required(maskEditor.developmentContext)
            let maskSession = maskEditor.developmentSession
            let binding = try Self.required(maskSession.source)
            let input = maskEditor.developmentMaskInput
            guard binding.sourceContentID == skySHA, maskSession.parameters.rawDecoder == .flashRaw031 else {
                throw ProbeFailure("The sky original or its selected FlashRaw decoder changed")
            }
            let timeline = MixedTimeline()
            let observation = input.$overlayRevision.dropFirst().sink { _ in
                if input.canAdopt, input.candidate?.target == .sky, input.candidate?.source == binding { timeline.mark("maskCandidate") }
            }
            defer { observation.cancel() }
            async let delivery = Self.deliverMixedPhotos(mixed, timeline: timeline)
            try await wait("first real JPEG delivery") { timeline.events["exportFirstFile"] != nil }
            async let intake = Self.importMixedRAWs(mixed, timeline: timeline)
            try await wait("first real Bayer DNG intake") { timeline.events["importFirstFile"] != nil }
            timeline.mark("maskRequested")
            input.begin(.sky, context: context)
            let originalMaskRecipe = maskSession.recipe
            var draws: [(sample: Draw, start: UInt64)] = []
            for position in 1...30 {
                let start = DispatchTime.now().uptimeNanoseconds
                canvas.setRecipe { $0.exposureEV = Double(position) * 0.029 }
                let accepted = try await drawn(canvas, recipe: canvas.recipe, quality: .settled, after: start, label: "mixed exposure \(position)")
                draws.append((accepted, start))
            }
            try await wait("fresh native Sky candidate", seconds: 120) { !input.busy }
            let candidate = try Self.required(input.candidate, input.note ?? "Sky inference returned no candidate")
            let diagnostics = try Self.required(await input.analysisDiagnostics(for: skySHA))
            guard input.canAdopt, candidate.target == .sky, candidate.source == binding, originalMaskRecipe == maskSession.recipe,
                  diagnostics.successfulGenerations == 1, diagnostics.exactCacheHits == 0, diagnostics.flashRawDecodes == 1,
                  diagnostics.landscapeRuns > 0, diagnostics.modelInvocations > 0 else {
                throw ProbeFailure("Sky candidate did not come from fresh, source-bound inference")
            }
            input.adopt(context: context)
            let layer = try Self.required(maskSession.parameters.masks.last)
            let snapshot = try Self.required(layer.semanticSnapshot)
            try snapshot.validate(png: Self.required(layer.subjectPNG))
            guard snapshot.source == binding, snapshot.target == .sky,
                  snapshot.modelHashes.contains(DevelopmentMaskModelPack.landscapeHash) else {
                throw ProbeFailure("The adopted layer lost its source or model identity")
            }
            let (files, imported) = try await (delivery, intake)
            let events = timeline.events
            let overlapStart = max(try Self.required(events["exportFirstFile"]),
                                   try Self.required(events["importFirstFile"]), try Self.required(events["maskRequested"]))
            let overlapEnd = min(try Self.required(events["exportLastFile"]),
                                 try Self.required(events["importLastFile"]), try Self.required(events["maskCandidate"]))
            let overlappingDraws = draws.filter { $0.start >= overlapStart && $0.sample.event.drawReturnedUptimeNanoseconds < overlapEnd }
            guard !overlappingDraws.isEmpty, files.count == mixed.assets.count, imported.status == "completed",
                  imported.completed == mixed.intakeCount, imported.failed == 0, try FileSafety.hash(sky) == skySHA,
                  try FileSafety.hash(foreground) == foregroundSHA else {
                throw ProbeFailure("Expected intact sources, completed input/output and a draw during all three real jobs. Events: \(events)")
            }
            let hashes = try Self.verifiedMixedDelivery(files, store: mixed.store)
            let report: [String: Any] = [
                "status": "passed", "timelineUptimeNS": events, "testBinarySHA256": try FileSafety.hash(Self.required(Bundle(for: Self.self).executableURL)),
                "fixtureManifestSHA256": mixed.fixtureSHA256, "importedRAWCount": imported.completed, "deliveryCount": files.count,
                "sourceSHA256": ["exposure": foregroundSHA, "mask": skySHA], "outputSHA256": hashes, "resultsMatchReceipts": true,
                "maskDiagnostics": Self.maskDiagnostics(diagnostics), "maskPNG": snapshot.pngSHA256, "maskModels": snapshot.modelHashes,
                "allDraws": draws.map { $0.sample.evidence(start: $0.start) },
                "allFrameStatistics": statistics(try draws.map { try $0.sample.duration(since: $0.start) }),
                "overlapFrameIDs": overlappingDraws.map { $0.sample.event.frameID.uuidString },
                "overlapFrameStatistics": statistics(try overlappingDraws.map { try $0.sample.duration(since: $0.start) }),
                "processMemory": try Self.maskProcessMemory()
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appending(path: "receipt.json"), options: .atomic)
        } catch {
            await canvas.shutdown()
            await maskEditor.shutdown()
            await mixed.model.editing?.shutdown()
            throw error
        }
        await canvas.shutdown()
        await maskEditor.shutdown()
        await mixed.model.editing?.shutdown()
        #endif
    }

    @MainActor func testOptIn035LocalFluxRegionThroughEditor() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAWMASTER_035_LIVE_FLUX"] == "1" else { throw XCTSkip("Enable the installed local FLUX Q8 replay") }
        #if DEBUG
        throw ProbeFailure("Use a Release test bundle for the real MLX replay")
        #else
        let out = URL(fileURLWithPath: try Self.required(env["RAWMASTER_035_FLUX_OUTPUT"]))
        let fixture = URL(fileURLWithPath: try Self.required(env["RAWMASTER_035_FLUX_PNG"]))
        let runtime = URL(fileURLWithPath: try Self.required(env["RAWMASTER_035_FLUX_ROOT"]))
        let originalSHA = "17e0c427790397572821339d541e9169b67a4dbb76123bd8d146a441d81c2034"
        guard try FileSafety.hash(fixture) == originalSHA else { throw ProbeFailure("Expected the signed 034 lake fixture") }
        var profile = QuickPromptModel.flux.defaultProfile
        profile.acceptedForUse = true
        profile.configuration = ["pythonExecutable": runtime.appending(path: "venv/bin/python").path,
                                 "runtimeDirectory": runtime.appending(path: "mlx").path,
                                 "weightsDirectory": runtime.appending(path: "models/q8").path]
        try LocalFluxProvider.validateConfiguration(profile)
        let fm = FileManager.default
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: false)
        let originals = out.appending(path: "originals")
        try fm.createDirectory(at: originals, withIntermediateDirectories: false)
        let source = originals.appending(path: "lake-input.png")
        try fm.copyItem(at: fixture, to: source)
        let db = out.appending(path: "catalog/library.sqlite")
        let asset = try Self.registerBenchmarkPhoto(source, database: db, sha256: originalSHA, projectName: "035 local FLUX")
        let store = try LibraryStore(databaseURL: db)
        try store.saveProviderProfile(profile)
        let suite = "RAWMaster035-LocalFlux-" + UUID().uuidString
        let defaults = try Self.required(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let model = AppModel(libraryURL: db, defaults: defaults)
        let editing = try Self.required(model.editing)
        editing.isPresented = true
        editing.focus(asset)
        let started = Date()
        var report: [String: Any] = [:]
        do {
            try await wait("local FLUX editing source and profile") {
                editing.canOpenQuickPrompt && editing.profiles.contains(where: { $0.id == profile.id })
            }
            let work = try Self.required(editing.work)
            let roi = QuickPromptPixelRegion(x: 480, y: 496, width: 512, height: 512)
            editing.stage = .versions
            editing.openQuickPrompt()
            editing.quickPromptDraft.prompt = "Remove the red stop sign and its pole. Reconstruct the water behind it, retaining the boats, water ripples and shoreline."
            editing.setQuickPromptScope(.rectangle(.init(x: 480.0/1024, y: 496.0/1024, width: 0.5, height: 0.5)))
            guard editing.quickPromptPresented, editing.providerOverride == nil, editing.quickPromptSubmissionIssue == nil else {
                throw ProbeFailure(editing.quickPromptSubmissionIssue ?? "Local editor did not open")
            }
            report["previewDuringFlux"] = try await exerciseFluxContention(editing, root: out, defaults: defaults)
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline, let state = editing.quickPromptJob?.state, !state.isTerminal && state != .outcomeUnknown {
                try await Task.sleep(for: .milliseconds(250))
            }
            let job = try Self.required(editing.quickPromptJob)
            guard job.state == .succeeded else { throw ProbeFailure(job.currentAttempt.error ?? "FLUX ended in " + job.state.rawValue) }
            try await wait("real archived local candidate") { editing.versions.count == 2 }
            let version = try store.editingVersion(id: Self.required(job.resultVersionID))
            let artifact = try Self.required(version.artifact)
            let snapshot = try Self.required(job.request.quickPrompt)
            let context = try Self.required(snapshot.context)
            let received = try Self.required(try store.receivedProcessingOutput(id: job.id))
            let finalURL = try store.editingArchive().artifactURL(artifact)
            let input = job.request.inputArtifact
            let cfg = received.configuration
            guard job.attempts.count == 1, job.currentAttempt.workerJoined, job.currentAttempt.submissionIntentAt != nil,
                  job.currentAttempt.remoteID == nil, received.remoteID == nil, job.request.profile.credentialReference == nil,
                  cfg["actualModel"] == LocalFluxProvider.modelID, cfg["runtimeRevision"] == LocalFluxProvider.runtimeRevision,
                  cfg["weightsRevision"] == LocalFluxProvider.weightsRevision, cfg["modelRevision"] == LocalFluxProvider.modelRevision,
                  cfg["usage"] == "local", cfg["preset"] == "q8-16", cfg["steps"] == "16", cfg["seed"] == "8521",
                  (Int64(cfg["peakMLXBytes"] ?? "") ?? 0) > 0, (Double(cfg["pipelineSeconds"] ?? "") ?? 0) > 0,
                  input.pixelWidth == 1024, input.pixelHeight == 1008, input.bitDepth == 8, input.encoding == "public.png",
                  try FileSafety.hash(job.request.inputFileURL) == input.sha256, snapshot.selection == roi, context.contains(roi),
                  try FileSafety.hash(snapshot.basis.url) == snapshot.basis.artifact.sha256,
                  try FileSafety.hash(received.fileURL) == received.artifact.sha256,
                  received.artifact.sha256 == version.configuration["quickPromptRawOutputSHA256"],
                  artifact.bitDepth == 16, artifact.pixelWidth == 1024, artifact.pixelHeight == 1024,
                  try FileSafety.hash(finalURL) == artifact.sha256, editing.work?.adoptedVersionID == work.originalVersionID else {
                throw ProbeFailure("The worker receipt, frozen input, raw output or unpublished candidate failed validation")
            }
            report["pixelComparison"] = try Self.compareFluxRegion(basis: snapshot.basis.url, candidate: finalURL, region: roi)
            editing.reviewQuickPrompt(job)
            try await wait("FLUX candidate review") { editing.quickPromptReview != nil }
            guard editing.canAdoptQuickPrompt else { throw ProbeFailure("Current original cannot adopt the candidate") }
            editing.applyQuickPromptReview()
            try await wait("explicit FLUX adoption") { editing.work?.adoptedVersionID == version.id && !editing.quickPromptPresented }
            let adopted = try store.photoWork(id: work.id)
            editing.undoQuickPrompt()
            try await wait("undo FLUX adoption") { editing.work?.adoptedVersionID == work.originalVersionID }
            let undone = try store.photoWork(id: work.id)
            guard adopted.adoptionRevision == work.adoptionRevision + 1, undone.adoptionRevision == adopted.adoptionRevision + 1 else {
                throw ProbeFailure("Adopt and undo did not produce consecutive durable revisions")
            }
            await editing.shutdown()
            let reopenedModel = AppModel(libraryURL: db, defaults: defaults)
            let reopened = try Self.required(reopenedModel.editing)
            reopened.isPresented = true
            reopened.focus(asset)
            do {
                try await wait("reopened real FLUX candidate") {
                    reopened.work?.id == work.id && reopened.versions.contains(where: { $0.id == version.id }) && reopened.jobs.contains(where: { $0.id == job.id })
                }
                let reopenedStore = try LibraryStore(databaseURL: db)
                let after = try reopenedStore.loadProcessingJobs(workID: work.id)
                let saved = try reopenedStore.editingVersion(id: version.id)
                guard reopened.work?.adoptedVersionID == work.originalVersionID, reopened.work?.adoptionRevision == undone.adoptionRevision,
                      after.count == 1, after.first?.attempts.map(\.runID) == [job.currentAttempt.runID], saved == version,
                      try FileSafety.hash(reopenedStore.editingArchive().artifactURL(Self.required(saved.artifact))) == artifact.sha256,
                      try FileSafety.hash(source) == originalSHA, try FileSafety.hash(fixture) == originalSHA else {
                    throw ProbeFailure("Reopening changed the source, attempt, archived bytes or adoption")
                }
            } catch {
                await reopened.shutdown()
                throw error
            }
            await reopened.shutdown()
            let binary = try Self.required(Bundle(for: EditingInteractionPerformanceTests.self).executableURL)
            report["testBinarySHA256"] = try FileSafety.hash(binary)
            report["sourceSHA256"] = originalSHA
            report["basisSHA256"] = snapshot.basis.artifact.sha256
            report["inputSHA256"] = input.sha256
            report["inputMatches034"] = input.sha256 == "2256f27433ff1e088df0638fc066606982009251f7669ae637d6cc9de3b06fb9"
            report["promptSHA256"] = DevelopmentSemanticMaskSnapshot.digest(Data(job.request.prompt.utf8))
            report["inputSize"] = [input.pixelWidth, input.pixelHeight]
            report["selectionTopLeftXYWH"] = [roi.x, roi.y, roi.width, roi.height]
            report["contextTopLeftXYWH"] = [context.x, context.y, context.width, context.height]
            report["receivedSHA256"] = received.artifact.sha256
            report["archivedSHA256"] = artifact.sha256
            report["archivedSize"] = [artifact.pixelWidth, artifact.pixelHeight]
            report["archivedBitDepth"] = artifact.bitDepth
            report["worker"] = cfg.filter { ["actualModel", "modelRevision", "weightsRevision", "runtimeRevision", "mlxVersion",
                "preset", "steps", "seed", "usage", "pipelineSeconds", "workerSeconds", "peakMLXBytes"].contains($0.key) }
            report["jobID"] = job.id
            report["attemptID"] = job.currentAttempt.id
            report["attemptsAfterReopen"] = 1
            report["originalVersionID"] = work.originalVersionID
            report["candidateVersionID"] = version.id
            report["adoptionRevisions"] = [work.adoptionRevision, adopted.adoptionRevision, undone.adoptionRevision]
            report["status"] = "passed"
            report["elapsedSeconds"] = Date().timeIntervalSince(started)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "receipt.json"), options: .atomic)
        } catch {
            await editing.shutdown()
            throw error
        }
        #endif
    }

    private static func registerBenchmarkPhoto(_ file: URL, database: URL, sha256: String, projectName: String) throws -> AssetRecord {
        guard try FileSafety.hash(file) == sha256 else { throw ProbeFailure("Different photo fixture") }
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try LibraryStore(databaseURL: database)
        let project = ProjectRecord(name: projectName)
        try store.saveProject(project)
        let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: file.deletingLastPathComponent().path,
            mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
        try store.saveSession(session)
        let asset = try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
            sourcePath: file.path, currentPath: file.path, filename: file.lastPathComponent, fileSize: try FileSafety.stat(file).size,
            contentHash: sha256, importState: .ready))
        try store.completedDirectImport(session)
        return asset
    }

    @MainActor private func exerciseFluxContention(_ editing: EditingController, root: URL, defaults: UserDefaults) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let other = repo.appending(path: "specs/030-ai-retouching/evidence/mountain-lake.jpg")
        let otherSHA = "503aa25139ab5cabccdc919c4e76643b97e51cf202643766d9606ad36406c442"
        let db = root.appending(path: "preview/library.sqlite")
        let asset = try Self.registerBenchmarkPhoto(other, database: db, sha256: otherSHA, projectName: "035 exposure canvas")
        let model = AppModel(libraryURL: db, defaults: defaults)
        let preview = try Self.required(model.editing)
        let mixed = try await prepareMixedDelivery(root: root, defaults: defaults)
        let host = NSHostingView(rootView: EditingImageCanvas(editing: preview).environmentObject(model))
        let window = NSWindow(contentRect: .init(x: 20, y: 20, width: 1024, height: 768), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // Hold memory only. The real worker must remain pre-submission while independent presentation is still eligible.
        let (held, acquired) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let budget = ProcessingAdmission.shared.capacity.memoryBytes
        let reservation = Task {
            defer { acquired.finish() }
            try await ProcessingAdmission.shared.withPermit(.library, resources: .init(memoryBytes: budget)) {
                acquired.finish()
                for await _ in released {}
            }
        }
        defer { release.finish(); reservation.cancel() }
        do {
            for await _ in held {}
            editing.prepareQuickPrompt()
            editing.prepareQuickPrompt()
            try await wait("FLUX waiting for physical resources") {
                editing.quickPromptJob?.state == .preparing || (!editing.quickPromptPreparing && editing.quickPromptNotice != nil)
            }
            let waiting = try Self.required(editing.quickPromptJob, editing.quickPromptNotice ?? "Missing local command")
            guard waiting.state == .preparing, waiting.currentAttempt.submissionIntentAt == nil else { throw ProbeFailure("FLUX submitted while memory was reserved") }
            let coldStart = DispatchTime.now().uptimeNanoseconds
            preview.isPresented = true
            preview.focus(asset)
            try await wait("second photo editing source") { preview.sourceReady && preview.previews.primary.frame != nil }
            preview.beginDevelopmentInterface()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let cold = try await drawn(preview, recipe: preview.recipe, quality: .settled, after: coldStart, label: "second window while FLUX waits")
            guard editing.quickPromptJob?.state == .preparing, editing.quickPromptJob?.currentAttempt.submissionIntentAt == nil else {
                throw ProbeFailure("FLUX escaped the reservation before the independent draw")
            }
            release.finish()
            try await reservation.value
            try await wait("real local FLUX worker started", seconds: 90) {
                guard let state = editing.quickPromptJob?.state else { return false }
                return state == .running || state.isTerminal || state == .outcomeUnknown
            }
            guard editing.quickPromptJob?.state == .running else { throw ProbeFailure(editing.quickPromptJob?.currentAttempt.error ?? "FLUX did not run") }
            let warm: Draw
            let warmStart: UInt64
            var mixedEvidence: [String: Any]?
            if let mixed {
                let timeline = MixedTimeline()
                async let delivery = Self.deliverMixedPhotos(mixed, timeline: timeline)
                try await wait("first mixed output delivered") { timeline.events["exportFirstFile"] != nil }
                async let intake = Self.importMixedRAWs(mixed, timeline: timeline)
                try await wait("first mixed RAW catalog commit") { timeline.events["importFirstFile"] != nil }
                (warm, warmStart) = try await drawAlongsideFlux(preview)
                let (files, imported) = try await (delivery, intake)
                let events = timeline.events
                let finishedDraw = warm.event.drawReturnedUptimeNanoseconds
                guard files.count == 200, imported.status == "completed", imported.completed == imported.discovered,
                      imported.completed == mixed.intakeCount, imported.failed == 0,
                      try Self.required(events["exportFirstFile"]) <= warmStart,
                      try Self.required(events["importFirstFile"]) <= warmStart,
                      try Self.required(events["exportLastFile"]) > finishedDraw,
                      try Self.required(events["importLastFile"]) > finishedDraw else {
                    throw ProbeFailure("Expected real export and RAW intake to span the canvas draw. Events: \(events)")
                }
                let fileHashes = try Self.verifiedMixedDelivery(files, store: mixed.store)
                mixedEvidence = ["timelineUptimeNS": events, "deliveryCount": files.count, "importedRAWCount": imported.completed,
                    "resultsMatchReceipts": true, "appHostMaxRSSBytes": LibraryGridPerformanceTests.rss(),
                    "outputSHA256": fileHashes, "fixtureManifestSHA256": mixed.fixtureSHA256]
            } else {
                (warm, warmStart) = try await drawAlongsideFlux(preview)
            }
            guard editing.quickPromptJob?.state == .running, try FileSafety.hash(other) == otherSHA else { throw ProbeFailure("The second draw did not overlap the running worker") }
            await preview.shutdown()
            await mixed?.model.editing?.shutdown()
            var evidence: [String: Any] = ["previewSourceSHA256": otherSHA, "heldMemoryBytes": budget,
                    "preSubmission": waiting.state.rawValue, "intentWhileWaiting": false,
                    "whileWaiting": cold.evidence(start: coldStart), "whileWaitingMs": try cold.duration(since: coldStart),
                    "whileRunning": warm.evidence(start: warmStart), "whileRunningMs": try warm.duration(since: warmStart)]
            if let mixedEvidence { evidence["mixedWorkload"] = mixedEvidence }
            return evidence
        } catch {
            release.finish()
            await preview.shutdown()
            await mixed?.model.editing?.shutdown()
            throw error
        }
    }

    @MainActor private func prepareMixedDelivery(root: URL, defaults: UserDefaults) async throws -> MixedDelivery? {
        guard let input = ProcessInfo.processInfo.environment["RAWMASTER_035_MIXED_EXPORT_ROOT"] else { return nil }
        let fixtures = URL(fileURLWithPath: input, isDirectory: true)
        let manifest = fixtures.appending(path: "inputs.json")
        let expected = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: manifest))
        let jpegs = try Self.required(expected["jpeg-source"])
        let raws = try Self.required(expected["raw-source"])
        guard jpegs.count == 200, raws.count >= 6, raws.keys.allSatisfy({ $0.hasSuffix(".dng") }) else {
            throw ProbeFailure("Mixed fixture requires 200 JPEG files and the frozen Bayer DNG set")
        }
        for (directory, entries) in [("jpeg-source", jpegs), ("raw-source", raws)] {
            let files = try FileManager.default.contentsOfDirectory(at: fixtures.appending(path: directory), includingPropertiesForKeys: nil)
            guard Set(files.map(\.lastPathComponent)) == Set(entries.keys),
                  try files.allSatisfy({ try FileSafety.hash($0) == entries[$0.lastPathComponent] }) else {
                throw ProbeFailure("Mixed fixture bytes differ for \(directory)")
            }
        }
        let database = root.appending(path: "mixed/catalog.sqlite")
        let store = try LibraryStore(databaseURL: database)
        _ = try await ImportService(store: store).importDirectory(source: fixtures.appending(path: "jpeg-source"), destination: nil,
            projectName: "035 mixed JPEG", mode: .reference, progress: { _ in })
        let model = AppModel(libraryURL: database, defaults: defaults, usesPagedLibrary: true)
        try await wait("mixed library opened") { !model.scopedAssets.isEmpty }
        model.openProjectExport()
        try await wait("200 mixed-workload photos") { model.exportWorkspacePresented && model.workbenchExportCandidates.count == 200 }
        return MixedDelivery(model: model, store: store, assets: Set(model.workbenchExportCandidates.map(\.id)),
            intake: fixtures.appending(path: "raw-source"), intakeCount: raws.count,
            destination: root.appending(path: "mixed/delivery"), fixtureSHA256: try FileSafety.hash(manifest))
    }

    @MainActor private static func deliverMixedPhotos(_ mixed: MixedDelivery, timeline: MixedTimeline) async throws -> [URL] {
        let result = try await mixed.model.exportWorkbenchPhotos(directory: mixed.destination, namingTemplate: "{name}",
            configuration: .init(format: .jpeg8, maximumLongEdge: 2048), includedIDs: mixed.assets,
            delivered: { _ in timeline.mark("exportFirstFile") }) { completed, total, _ in
                if completed == 0 { timeline.mark("exportPrepared") }
                if completed == total { timeline.mark("exportLastFile") }
            }
        timeline.mark("exportCompleted")
        return result
    }

    private static func importMixedRAWs(_ mixed: MixedDelivery, timeline: MixedTimeline) async throws -> ImportSession {
        let session = try await ImportService(store: mixed.store).importDirectory(source: mixed.intake, destination: nil,
            projectName: "035 concurrent Bayer intake", mode: .reference) { progress in
                if progress.isRunning, progress.completed > 0 { timeline.mark("importFirstFile") }
                if progress.isRunning, progress.completed == mixed.intakeCount { timeline.mark("importLastFile") }
            }
        timeline.mark("importCompleted")
        return session
    }

    private static func verifiedMixedDelivery(_ files: [URL], store: LibraryStore) throws -> [String: String] {
        let hashes = Dictionary(uniqueKeysWithValues: try files.map { (FileSafety.canonical($0).path, try FileSafety.hash($0)) })
        let receipts = try store.rows("""
            SELECT json_extract(m.value,'$.destination.pathHint') || '/' || json_extract(i.value,'$.ticket.filename'),
                   json_extract(i.value,'$.ticket.sha256')
            FROM lc_meta i JOIN lc_meta m ON m.key='wb032.manifest.v1/'||substr(i.key,length('wb032.item.v1/')+1,36)
            WHERE i.key GLOB 'wb032.item.v1/*' AND json_extract(i.value,'$.state')='delivered'
            """)
        let unsettled = try store.rows("SELECT count(*) FROM lc_task_jobs WHERE state IN ('queued','running','cancelling','reconcile')")
        guard receipts.count == hashes.count, Set(receipts.map { $0[0] }) == Set(hashes.keys),
              receipts.allSatisfy({ hashes[$0[0]] == $0[1] }), unsettled == [["0"]] else {
            throw ProbeFailure("Mixed catalog still has work or the delivery receipts do not match the individual files")
        }
        return hashes
    }

    @MainActor private func drawAlongsideFlux(_ preview: EditingController) async throws -> (Draw, UInt64) {
        let start = DispatchTime.now().uptimeNanoseconds
        preview.setRecipe { $0.exposureEV = 0.42 }
        let frame = try await drawn(preview, recipe: preview.recipe, quality: .settled, after: start, label: "second window alongside MLX")
        return (frame, start)
    }

    private static func compareFluxRegion(basis: URL, candidate: URL, region: QuickPromptPixelRegion) throws -> [String: Int] {
        func decode(_ url: URL) throws -> CGImage {
            let source = try required(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try required(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let before = try decode(basis), after = try decode(candidate)
        guard before.width == 1024, before.height == 1024, after.width == before.width, after.height == before.height,
              before.bitsPerComponent == 16, after.bitsPerComponent == 16,
              before.bitsPerPixel == after.bitsPerPixel, before.bitmapInfo == after.bitmapInfo else { throw ProbeFailure("Incompatible TIFF16 pixel layouts") }
        let a = try required(before.dataProvider?.data), b = try required(after.dataProvider?.data)
        let p = try required(CFDataGetBytePtr(a)), q = try required(CFDataGetBytePtr(b))
        let stride = before.bitsPerPixel / 8
        var inside = 0, outside = 0
        for y in 0..<before.height {
            for x in 0..<before.width {
                if memcmp(p + y * before.bytesPerRow + x * stride, q + y * after.bytesPerRow + x * stride, stride) != 0 {
                    if x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height { inside += 1 }
                    else { outside += 1 }
                }
            }
        }
        guard inside > 0, outside == 0 else { throw ProbeFailure("Selected changed pixels \(inside), protected changed pixels \(outside)") }
        return ["selectedPixels": region.width * region.height, "selectedChangedPixels": inside,
                "protectedPixels": before.width * before.height - region.width * region.height, "protectedChangedPixels": outside]
    }
}

