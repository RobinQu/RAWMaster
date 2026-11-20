import Foundation
import Combine
import XCTest
import RAWMasterAI
import RAWMasterCore
@testable import RAWMaster

final class ApplicationEditingServicesTests: XCTestCase {
    @MainActor func testAwaitedProfileReloadsPublishUsableSnapshotAcrossStartup() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = ProfileReadGate()
        let services = ApplicationEditingServices(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, credentials: LifecycleMemoryCredentials())
        services.profileReadHook = { await gate.suspendRead() }
        var completed = 0, publishedCloudProfile = false
        let observation = services.$profiles.sink { profiles in
            if profiles.contains(where: { $0.kind == .openAI }) { publishedCloudProfile = true }
        }
        let first = Task { await services.reloadProfiles(); completed += 1; return services.profiles }
        let second = Task { await services.reloadProfiles(); completed += 1; return services.profiles }
        await gate.waitUntilEntered()
        XCTAssertEqual(completed, 0)
        await gate.releaseReads()
        let firstProfiles = await first.value, secondProfiles = await second.value
        XCTAssertTrue(firstProfiles.contains { $0.kind == .openAI })
        XCTAssertEqual(firstProfiles, secondProfiles)
        XCTAssertTrue(publishedCloudProfile, "Awaited reload must publish the real Settings projection before returning")
        await services.reloadProfiles()
        XCTAssertEqual(services.profiles, firstProfiles, "Unsaved catalog rows must retain their UI identity across refreshes")
        observation.cancel()
        await services.shutdown()
    }

    @MainActor func testReloadDuringProfileSaveWaitsForPersistedCredentialSnapshot() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = ProfileReadGate()
        let services = ApplicationEditingServices(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, credentials: LifecycleMemoryCredentials())
        services.profileReadHook = { await gate.suspendRead() }
        let initialRead = Task { await services.reloadProfiles() }
        await gate.waitUntilEntered()
        var profile = try XCTUnwrap(ProviderCatalog.examples.first { $0.kind == .openAI })
        profile.acceptedForUse = true; profile.displayName = "Saved cloud configuration"
        let mutationClaimed = Task {
            for await saving in services.$providerSaving.values { if saving { return } }
        }
        let save = Task { try await services.saveProfile(profile, secret: "unusable-test-credential") }
        await mutationClaimed.value
        let reload = Task { await services.reloadProfiles(); return services.profiles }
        await gate.releaseReads()
        await initialRead.value; try await save.value
        let reloaded = await reload.value
        let saved = try XCTUnwrap(reloaded.first { $0.kind == .openAI })
        XCTAssertEqual(saved.id, profile.id)
        XCTAssertEqual(saved.displayName, profile.displayName)
        XCTAssertNotNil(saved.credentialReference)
        XCTAssertEqual(try fixture.store.loadProviderProfiles().first?.id, profile.id)
        await services.shutdown()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Timed out waiting for controlled lifecycle state")
    }
    @MainActor private func cloudController(_ fixture: EditingWorkflowTests.Fixture, provider: any AIEditingProvider) async throws -> EditingController {
        let services = ApplicationEditingServices(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, credentials: LifecycleMemoryCredentials())
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, applicationServices: services)
        await editing.reloadProfiles()
        var profile = try XCTUnwrap(editing.profiles.first { $0.kind == .openAI })
        profile.acceptedForUse = true
        try await editing.saveProfile(profile, secret: "unusable-test-credential")
        editing.selectedProfileID = profile.id; editing.providerOverride = provider
        editing.focus(fixture.assets[0]); try await waitUntil { editing.work != nil }
        return editing
    }
    @MainActor func testApplicationOwnsOneEnvironmentAndPhotoSettingsOnlyRoute() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let services = try XCTUnwrap(model.editingServices)
        let editing = try XCTUnwrap(model.editing)
        XCTAssertFalse(services.licenseAccepted, "Application startup cannot accept model terms for the user")
        XCTAssertTrue(editing.applicationServices === services)
        XCTAssertTrue(services.runtime === services.coordinator.runtime)
        let firstRequest = model.settingsRequestID
        editing.showSettings = true
        XCTAssertEqual(model.settingsPage, .cloudServices)
        XCTAssertNotEqual(model.settingsRequestID, firstRequest)
        XCTAssertFalse(editing.showSettings, "Photo settings must route to the app window, not retain an old sheet")
        editing.leaveBrowsingContext()
        XCTAssertTrue(model.editingServices === services, "Closing a photo cannot replace application services")
        let nextRequest = model.settingsRequestID
        model.openApplicationSettings(.localAI)
        XCTAssertNotEqual(model.settingsRequestID, nextRequest)
        XCTAssertTrue(model.editingServices?.runtime === services.runtime)
        await editing.shutdown()
        // An injected photo controller never shuts down its application runtime owner.
        let operation = SettingsRuntimeJoinGate()
        services.runtimeActionOverride = { try await operation.run() }
        services.performRuntimeAction { _ in }
        for _ in 0..<200 { if await operation.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await operation.started; XCTAssertTrue(started)
        let shutdown = Task { await services.shutdown() }
        for _ in 0..<200 { if await operation.cancelled { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        await operation.releaseJoin()
        await shutdown.value
        await editing.finishPreviewShutdown()
    }

    @MainActor func testDatabaseFailureKeepsSettingsModelWithoutReplacementServices() throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let unavailableLibrary = fixture.root.appendingPathComponent("unavailable.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: unavailableLibrary, withIntermediateDirectories: false)
        let model = AppModel(libraryURL: unavailableLibrary, defaults: fixture.defaults)
        XCTAssertEqual(model.libraryURL, unavailableLibrary)
        XCTAssertNil(model.editingServices)
        XCTAssertNil(model.editing)
        XCTAssertNotNil(model.errorMessage)
        model.openApplicationSettings(.diagnostics)
        XCTAssertEqual(model.settingsPage, .diagnostics)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: unavailableLibrary.path).isEmpty)
    }

    @MainActor func testTerminationDuringInputPreparationJoinsBeforeAnyEnqueue() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        editing.focus(fixture.assets[0])
        for _ in 0..<500 {
            if editing.work != nil && !editing.profiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(editing.work)
        var profile = try XCTUnwrap(editing.profiles.first { $0.kind == .localComfy })
        profile.acceptedForUse = true
        try await editing.saveProfile(profile, secret: nil)
        editing.selectedProfileID = profile.id
        let operation = SettingsRuntimeJoinGate()
        editing.generationPreparationHook = { try await operation.run() }
        editing.generate()
        for _ in 0..<200 { if await operation.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await operation.started; XCTAssertTrue(started)
        var returned = false
        let shutdown = Task { await editing.shutdown(); returned = true }
        for _ in 0..<200 { if await operation.cancelled { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let cancelled = await operation.cancelled; XCTAssertTrue(cancelled)
        XCTAssertFalse(returned, "Termination must join input preparation even before a processing job exists")
        XCTAssertTrue(try fixture.store.loadProcessingJobs().isEmpty)
        await operation.releaseJoin()
        await shutdown.value
        XCTAssertTrue(returned)
        XCTAssertFalse(editing.saving)
        XCTAssertTrue(try fixture.store.loadProcessingJobs().isEmpty, "Cancelled input must never become queued or outcome unknown")
        XCTAssertTrue(try fixture.store.loadRenderedExports().isEmpty)
        editing.generate()
        XCTAssertTrue(try fixture.store.loadProcessingJobs().isEmpty, "Termination closes new generation admission")
    }

    @MainActor func testTerminationJoinsRetryAdmissionAndCancelsOnlyUnsubmittedAttempt() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let provider = LifecycleUnknownProvider()
        let editing = try await cloudController(fixture, provider: provider)
        editing.generate()
        try await waitUntil { editing.jobs.first?.state == .outcomeUnknown && !editing.saving }
        try await waitUntil { editing.runningJobCount == 0 }
        let original = try XCTUnwrap(editing.jobs.first)
        let gate = SettingsRuntimeJoinGate()
        editing.retryAdmissionHook = { try await gate.run() }
        editing.retry(original, allowUnknown: true) // Explicit user-approved retry; never automatic.
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await gate.started; XCTAssertTrue(started)
        let retry = try fixture.store.processingJob(id: original.id)
        XCTAssertEqual(retry.attempts.count, 2)
        editing.scheduleQueuedJobs()
        await Task.yield()
        XCTAssertEqual(editing.runningJobCount, 0, "Background scheduling cannot bypass the pending retry admission")
        var returned = false
        let shutdown = Task { await editing.shutdown(); returned = true }
        for _ in 0..<200 { if await gate.cancelled { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let cancelled = await gate.cancelled; XCTAssertTrue(cancelled)
        XCTAssertFalse(returned)
        await gate.releaseJoin(); await shutdown.value
        let final = try fixture.store.processingJob(id: original.id)
        XCTAssertEqual(final.currentAttempt.state, .cancelled)
        XCTAssertNil(final.currentAttempt.submissionIntentAt)
        XCTAssertEqual(final.attempts.first?.state, .outcomeUnknown, "Prior submitted cloud outcome must remain unknown")
        let calls = await provider.editCalls; XCTAssertEqual(calls, 1)
        editing.retry(final)
        XCTAssertEqual(try fixture.store.processingJob(id: original.id).attempts.count, 2)
        await editing.applicationServices.shutdown()
    }

    @MainActor func testTerminationJoinsLateReconciliationAndPreservesReceivedOutputWithoutArchiving() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let gate = SettingsRuntimeJoinGate(), provider = LifecycleUnknownProvider()
        await provider.setReconciliationGate(gate)
        let editing = try await cloudController(fixture, provider: provider)
        editing.generate()
        try await waitUntil { editing.jobs.first?.state == .outcomeUnknown && !editing.saving }
        let original = try XCTUnwrap(editing.jobs.first)
        editing.reconcile(original)
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await gate.started; XCTAssertTrue(started)
        var returned = false
        let shutdown = Task { await editing.shutdown(); returned = true }
        for _ in 0..<200 { if await gate.cancelled { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let cancelled = await gate.cancelled; XCTAssertTrue(cancelled)
        XCTAssertFalse(returned, "An in-flight reconciliation must actually join before app services close")
        await gate.releaseJoin(); await shutdown.value
        let final = try fixture.store.processingJob(id: original.id)
        XCTAssertEqual(final.state, .outcomeUnknown)
        XCTAssertNil(final.resultVersionID)
        XCTAssertNotNil(final.currentAttempt.receivedOutput, "A late received result is durable, without publishing a candidate during termination")
        XCTAssertEqual(try fixture.store.loadEditingVersions(workID: final.request.workID).count, 1)
        let edits = await provider.editCalls, reconciliations = await provider.reconcileCalls
        XCTAssertEqual(edits, 1); XCTAssertEqual(reconciliations, 1)
        editing.reconcile(final)
        let unchanged = await provider.reconcileCalls; XCTAssertEqual(unchanged, 1)
        await editing.applicationServices.shutdown()
    }
}

private actor ProfileReadGate {
    private(set) var readCount = 0
    private var entered = false, released = false
    private var readers: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func suspendRead() async {
        readCount += 1; entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters = []
        guard !released else { return }
        await withCheckedContinuation { readers.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func releaseReads() {
        released = true
        for reader in readers { reader.resume() }; readers = []
    }
}

private actor LifecycleUnknownProvider: AIEditingProvider {
    private(set) var editCalls = 0
    private(set) var reconcileCalls = 0
    private var gate: SettingsRuntimeJoinGate?
    func setReconciliationGate(_ gate: SettingsRuntimeJoinGate) { self.gate = gate }
    func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
        editCalls += 1; throw AIServiceError.outcomeUnknown
    }
    func cancel(attempt: ProcessingAttempt) async throws { throw AIServiceError.outcomeUnknown }
    func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult {
        reconcileCalls += 1
        guard let gate else { return .unknown }
        do { try await gate.run() } catch { /* Deliberately deliver a late received result after cancellation. */ }
        return .completed(.init(fileURL: request.inputFileURL, artifact: request.inputArtifact, configuration: ["fixture": "late-reconciliation"]))
    }
}

private final class LifecycleMemoryCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (destination: String, secret: String)] = [:]
    func save(_ secret: String, for profile: AIProviderProfile) throws -> String {
        let destination = try ProviderDestination.canonical(profile.endpoint), id = UUID().uuidString
        lock.lock(); defer { lock.unlock() }; values[id] = (destination, secret); return id
    }
    func secret(reference: String, for profile: AIProviderProfile) throws -> String {
        let destination = try ProviderDestination.canonical(profile.endpoint)
        lock.lock(); defer { lock.unlock() }
        guard let stored = values[reference], stored.destination == destination else { throw AIServiceError.credentialUnavailable }
        return stored.secret
    }
    func delete(reference: String) { lock.lock(); defer { lock.unlock() }; values[reference] = nil }
}

private actor SettingsRuntimeJoinGate {
    private(set) var started = false
    private(set) var cancelled = false
    private var joinWaiter: CheckedContinuation<Void, Never>?
    func run() async throws {
        started = true
        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
        catch {
            cancelled = true
            await withCheckedContinuation { joinWaiter = $0 }
            throw error
        }
    }
    func releaseJoin() { joinWaiter?.resume(); joinWaiter = nil }
}
