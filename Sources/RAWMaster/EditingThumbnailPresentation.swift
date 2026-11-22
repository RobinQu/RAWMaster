import AppKit
import Combine
import RAWMasterCore
import RAWMasterImaging

extension DevelopmentThumbnailKind {
    var presentationKey: String { switch self { case .summary(let group): return group.rawValue; case .filters: return "filters" } }
}

/// A bounded metadata mailbox, not a per-progress Task or a second image worker.
private final class ThumbnailProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DevelopmentThumbnailProgress?
    func put(_ value: DevelopmentThumbnailProgress) { lock.lock(); latest = value; lock.unlock() }
    func get() -> DevelopmentThumbnailProgress? { lock.lock(); defer { lock.unlock() }; return latest }
}

/// One current visible set per kind. Images alias Service-owned immutable provider storage.
@MainActor final class EditingThumbnailPresentation: ObservableObject {
    struct VisibleSet {
        let key: String
        let registration: DevelopmentThumbnailRegistration
        let lease: DevelopmentThumbnailPresentationLease
        let images: [NSImage]
    }
    enum State: String, Equatable { case idle, waitingForSource, queued, preparing, ready, unavailable, failed
        var isBusy: Bool { self == .queued || self == .preparing }
    }
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var sets: [String: VisibleSet] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var refreshing: Set<String> = []
    private weak var editing: EditingController?
    private var visible: [String: DevelopmentThumbnailKind] = [:]
    private struct Attempt { let key: String; let witness: EditingThumbnailCanonicalWitness?; let automaticRetryUsed: Bool }
    private var attempts: [String: Attempt] = [:]
    private struct Retirement { let lease: DevelopmentThumbnailPresentationLease; let registration: DevelopmentThumbnailRegistration }
    private var retirements: [Retirement] = []
    private var generation: UInt64 = 1
    @Published private(set) var driving = false
    private var child: Task<DevelopmentThumbnailReadyLease, Error>?
    private var active: DevelopmentThumbnailRegistration?
    private let progress = ThumbnailProgressMailbox()
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var retryCounts: [String: Int] = [:]
    init(editing: EditingController) { self.editing = editing }
    private var shouldTraceActivity: Bool {
        InteractionTrace.shared.isEnabled && (editing?.developmentContext != nil || !visible.isEmpty || !retirements.isEmpty)
    }
    static func cacheKey(_ request: DevelopmentThumbnailRequest, context: EditingInteractionContext) -> String {
        // Focus restoration creates a new interaction epoch and may publish a new preview revision,
        // but neither changes thumbnail pixels. Key only the immutable source/branch and recipe inputs.
        String(reflecting: context.historyKey) + ":source:" + String(context.sourceGeneration)
            + ":" + request.presentedRecipeFingerprint + ":" + request.kind.presentationKey + ":" + request.basis.rawValue
            + ":" + String(reflecting: request.preview.quality) + ":" + String(request.preview.viewport.maxPixel)
            + ":" + (request.expectedPhotoFilterResourceVersion ?? "none")
    }
    private func key(_ request: DevelopmentThumbnailRequest, context: EditingInteractionContext) throws -> String {
        guard let editing else { throw DevelopmentThumbnailError.closed }
        return try editing.developmentThumbnailContentKey(request, context: context)
    }
    func setVisible(_ kind: DevelopmentThumbnailKind, _ value: Bool, context: EditingInteractionContext) {
        let scopeMatch = editing?.developmentContext == context
        InteractionTrace.shared.thumbnail(.ownerVisible, kind: kind) {
            let hadKind = visible[kind.presentationKey] != nil
            let after = visible.count + (scopeMatch ? (value ? (hadKind ? 0 : 1) : (hadKind ? -1 : 0)) : 0)
            return .init(reason: scopeMatch ? .accepted : .staleScope,
                flags: [.scopeMatch: scopeMatch, .requestedVisible: value, .previouslyVisible: hadKind, .editingPresent: editing != nil],
                numbers: [.visibleBefore: Double(visible.count), .visibleAfter: Double(after)], state: state(kind))
        }
        guard scopeMatch else { return }
        let id = kind.presentationKey
        if value { visible[id] = kind } else {
            visible[id] = nil; cancelRetry(id)
            if loading.contains(id) { child?.cancel() }
            // Keep the bounded adopted image set while scrolled off-screen or otherwise hidden.
            // A real recipe/source change still invalidates it through recipeChanged()/invalidate().
            states[id] = sets[id] == nil ? .idle : .ready
        }
        refresh()
    }
    private func cancelRetry(_ id: String) {
        retryTasks.removeValue(forKey: id)?.cancel(); retryCounts.removeValue(forKey: id)
    }
    private func cancelAllRetries() {
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll(); retryCounts.removeAll()
    }
    private func scheduleFilterRetry(_ id: String) {
        guard id == DevelopmentThumbnailKind.filters.presentationKey, visible[id] != nil,
              retryTasks[id] == nil, retryCounts[id, default: 0] < 5 else { return }
        let count = retryCounts[id, default: 0], delay: UInt64 = [50, 100, 200, 400, 800][count] * 1_000_000
        retryCounts[id] = count + 1
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.retryTasks[id] = nil; self?.attempts[id] = nil; self?.refresh()
        }
    }
    func retry(_ kind: DevelopmentThumbnailKind, context: EditingInteractionContext) {
        let scopeMatch = editing?.developmentContext == context, isVisible = visible[kind.presentationKey] != nil
        InteractionTrace.shared.thumbnail(.retry, kind: kind) {
            var flags: [ThumbnailDiagnosticFlag: Bool] = [.scopeMatch: scopeMatch, .editingPresent: editing != nil]
            // A diagnostic must not initialize a lazily-created editing session.
            if editing?.developmentContext != nil { flags[.noActiveGesture] = editing?.developmentSession.activeGesture == nil }
            return .init(reason: !scopeMatch ? .staleScope : (isVisible ? .accepted : .notVisible), flags: flags,
                numbers: [.visibleCount: Double(visible.count)], state: state(kind))
        }
        guard scopeMatch, isVisible else { return }
        cancelRetry(kind.presentationKey)
        attempts[kind.presentationKey] = nil; errors[kind.presentationKey] = nil; refresh()
    }
    func state(_ kind: DevelopmentThumbnailKind) -> State { states[kind.presentationKey] ?? .idle }
    func isRefreshing(_ kind: DevelopmentThumbnailKind) -> Bool { refreshing.contains(kind.presentationKey) }
    private func mayAttempt(_ id: String, key: String, witness: EditingThumbnailCanonicalWitness?) -> Bool {
        if sets[id]?.key == key { refreshing.remove(id); return false }
        guard let last = attempts[id], last.key == key else { return true }
        if id == DevelopmentThumbnailKind.filters.presentationKey {
            return !last.automaticRetryUsed && states[id] == .waitingForSource
        }
        return !last.automaticRetryUsed && states[id] == .waitingForSource && witness != nil && last.witness != witness
    }
    func progressText(_ kind: DevelopmentThumbnailKind) -> String {
        if let value = progress.get(), value.registration == active { return "准备预览 \(value.completed)/\(value.total)" }
        return "正在准备预览…"
    }
    private func detach(_ id: String) {
        refreshing.remove(id); cancelRetry(id)
        if let old = sets.removeValue(forKey: id) { retirements.append(.init(lease: old.lease, registration: old.registration)) }
    }
    func recipeChanged() {
        generation &+= 1; child?.cancel(); cancelAllRetries()
        for id in Array(sets.keys) where id != DevelopmentThumbnailKind.filters.presentationKey { detach(id) }
        attempts = [:]; errors = [:]
        refreshing = Set(sets.keys)
        states = visible.mapValues { kind in sets[kind.presentationKey] == nil ? .waitingForSource : .queued }
        ensureDriver()
    }
    func pause() { recipeChanged(); ensureDriver() }
    func invalidate() {
        visible = [:]; recipeChanged()
        for id in Array(sets.keys) { detach(id) }
        refreshing.removeAll(); ensureDriver()
    }
    func refresh() {
        if shouldTraceActivity {
            InteractionTrace.shared.thumbnail(.refresh) {
                .init(flags: [.contextPresent: editing?.developmentContext != nil, .driving: driving, .childPresent: child != nil,
                              .witnessAvailable: editing?.developmentThumbnailCanonicalWitness() != nil],
                    numbers: [.visibleCount: Double(visible.count), .retirementCount: Double(retirements.count)])
            }
        }
        guard let editing, let context = editing.developmentContext else { return }
        for (id, kind) in visible {
            guard let request = try? editing.developmentThumbnailRequest(kind, registration: .init(visibleGeneration: generation)) else {
                child?.cancel()
                if sets[id] == nil { states[id] = .waitingForSource }
                continue
            }
            guard let wanted = try? key(request, context: context) else { continue }
            if let old = sets[id], old.key != wanted {
                attempts[id] = nil
                if kind == .filters { refreshing.insert(id); states[id] = .queued }
                else { detach(id) }
            } else if sets[id] != nil { refreshing.remove(id); states[id] = .ready }
        }
        ensureDriver()
    }
    private func ensureDriver() {
        guard !driving, let editing, !visible.isEmpty || !retirements.isEmpty else {
            if shouldTraceActivity {
                InteractionTrace.shared.thumbnail(.driver) {
                    .init(reason: driving ? .alreadyDriving : (editing == nil ? .noContext : .noVisible),
                        flags: [.driving: driving, .childPresent: child != nil],
                        numbers: [.visibleCount: Double(visible.count), .retirementCount: Double(retirements.count)])
                }
            }
            return
        }
        if retirements.isEmpty {
            var reason: ThumbnailDiagnosticReason = .noContext
            guard let context = editing.developmentContext, visible.contains(where: { id, kind in
                guard let request = try? editing.developmentThumbnailRequest(kind, registration: .init(visibleGeneration: generation)) else {
                    reason = .requestRejected; return false
                }
                guard let wanted = try? key(request, context: context) else { reason = .requestRejected; return false }
                let allowed = mayAttempt(id, key: wanted, witness: editing.developmentThumbnailCanonicalWitness())
                reason = allowed ? .scheduled : (sets[id]?.key == wanted ? .alreadyCurrent : .attemptExhausted)
                return allowed
            }) else {
                InteractionTrace.shared.thumbnail(.driver) {
                    .init(reason: reason, numbers: [.visibleCount: Double(visible.count)])
                }
                return
            }
        }
        driving = true
        let admitted = editing.runDevelopmentThumbnailOperation({ [self] in await drive() })
        if !admitted { driving = false }
        InteractionTrace.shared.thumbnail(.driver) {
            .init(reason: admitted ? (retirements.isEmpty ? .scheduled : .retirementOnly) : .operationAdmissionRejected,
                flags: [.driving: driving, .childPresent: child != nil],
                numbers: [.visibleCount: Double(visible.count), .retirementCount: Double(retirements.count)])
        }
    }
    /// Actual adoption metadata gate; tests invoke this same function without constructing image leases.
    static func validateAdoptionDescriptor(_ descriptor: DevelopmentThumbnailSetDescriptor,
        request: DevelopmentThumbnailRequest, source: DevelopmentLocalEditSourceBinding?, resourceVersion: String?) throws {
        let filter = request.preview.recipe.adjustmentsV3?.filter
        let needsFilterResource = request.kind == .filters
            || (filter?.enabled == true && filter?.selection != .original && filter?.intensity != 0)
        guard descriptor.presentationMode == .managedImage, descriptor.presentationVersion == "thumbnail-managed-rgba8-provider-v1",
              descriptor.actualRequest.recipe == request.preview.recipe,
              descriptor.actualRequest.role == request.preview.role, descriptor.actualRequest.quality == request.preview.quality,
              descriptor.actualRequest.viewport == request.preview.viewport,
              descriptor.target == request.target, descriptor.contractVersion == request.contractVersion,
              descriptor.registration == request.registration, descriptor.expectedRecipeFingerprint == request.expectedRecipeFingerprint,
              descriptor.presentedRecipeFingerprint == request.presentedRecipeFingerprint,
              descriptor.actualRequest.sessionID == request.preview.sessionID,
              descriptor.actualRequest.sourceGeneration == request.preview.sourceGeneration,
              descriptor.actualRequest.consumerID == request.preview.consumerID,
              descriptor.actualRequest.revision == request.preview.revision,
              descriptor.sourceBinding == source,
              descriptor.kind == request.kind, descriptor.tiles.count == request.kind.count,
              (!needsFilterResource || (resourceVersion?.isEmpty == false && request.expectedPhotoFilterResourceVersion == resourceVersion
                                       && descriptor.photoFilterResourceVersion == resourceVersion)) else { throw DevelopmentThumbnailError.staleSource }
    }
    private func drive() async {
        defer { driving = false; child = nil; active = nil; loading = [] }
        guard let editing else { return }
        let backend = editing.previews.primary.thumbnailBackend
        while true {
            while !retirements.isEmpty {
                let old = retirements.removeFirst()
                // Clear all App NSImage wrappers before releasing Service ownership. Escaped aliases
                // keep their provider ticket charged; release never waits for arbitrary UI references.
                await backend.releaseThumbnails(old.lease, registration: old.registration)
            }
            guard !Task.isCancelled, let context = editing.developmentContext else { break }
            var next: (String, DevelopmentThumbnailRequest, String)?
            for id in visible.keys.sorted() {
                guard let kind = visible[id], let request = try? editing.developmentThumbnailRequest(kind, registration: .init(visibleGeneration: generation)),
                      let wanted = try? key(request, context: context) else { continue }
                if mayAttempt(id, key: wanted, witness: editing.developmentThumbnailCanonicalWitness()) { next = (id, request, wanted); break }
            }
            guard let (id, request, wanted) = next else { break }
            let automaticRetry = attempts[id]?.key == wanted
            attempts[id] = .init(key: wanted, witness: editing.developmentThumbnailCanonicalWitness(), automaticRetryUsed: automaticRetry)
            active = request.registration; loading = [id]; refreshing.insert(id); errors[id] = nil; states[id] = .queued
            let mailbox = progress
            let task = Task { try await backend.thumbnails(request, progress: { mailbox.put($0) }) }
            child = task; states[id] = .preparing
            var ready: DevelopmentThumbnailReadyLease?
            var presentation: DevelopmentThumbnailPresentationLease?
            var published = false
            var terminalReason: ThumbnailDiagnosticReason = .accepted
            do {
                ready = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                guard !task.isCancelled, visible[id] != nil, generation == request.registration.visibleGeneration,
                      let currentContext = editing.developmentContext,
                      currentContext.historyKey == context.historyKey,
                      currentContext.sourceGeneration == context.sourceGeneration,
                      let current = try? editing.developmentThumbnailRequest(request.kind, registration: request.registration),
                      (try? key(current, context: currentContext)) == wanted, let value = ready else { throw DevelopmentThumbnailError.superseded }
                try Self.validateAdoptionDescriptor(value.descriptor, request: request,
                    source: editing.developmentSession.source, resourceVersion: editing.developmentSourceFacts?.photoFilterResourceVersion)
                let lease = try await backend.adoptThumbnails(value, registration: request.registration)
                presentation = lease; ready = nil
                guard !task.isCancelled, !Task.isCancelled,
                      let currentContext = editing.developmentContext,
                      currentContext.historyKey == context.historyKey,
                      generation == request.registration.visibleGeneration, visible[id] != nil,
                      let current = try? editing.developmentThumbnailRequest(request.kind, registration: request.registration),
                      (try? key(current, context: currentContext)) == wanted else { throw DevelopmentThumbnailError.superseded }
                let images = try lease.tiles.map { tile in
                    NSImage(cgImage: try lease.cgImage(tile: tile.index), size: .init(width: tile.width, height: tile.height))
                }
                detach(id)
                sets[id] = .init(key: wanted, registration: request.registration, lease: lease, images: images)
                presentation = nil; refreshing.remove(id); states[id] = .ready; published = true
            } catch {
                terminalReason = .error(error); refreshing.remove(id)
                if !Task.isCancelled, generation == request.registration.visibleGeneration,
                   editing.developmentContext == context, visible[id] != nil {
                    // A terminal is never displayed as a still-running native operation. Keep its
                    // attempted witness so routine refresh cannot turn it into an automatic loop.
                    states[id] = .failed
                    if task.isCancelled { states[id] = .waitingForSource; errors[id] = nil }
                    else if let error = error as? DevelopmentThumbnailError {
                        switch error {
                        case .unsupportedGraph:
                            states[id] = .unavailable; errors[id] = "当前调整组合的效果预览尚不可用。"
                        case .awaitingSource, .staleSource, .superseded, .closed, .cancelled:
                            states[id] = .waitingForSource; errors[id] = nil
                        case .budgetUnavailable: errors[id] = "预览资源正在释放，请稍后重试。"
                        default: errors[id] = "未能准备效果预览，请重试。"
                        }
                    } else { errors[id] = "未能准备效果预览，请重试。" }
                    if id == DevelopmentThumbnailKind.filters.presentationKey,
                       let thumbnailError = error as? DevelopmentThumbnailError {
                        switch thumbnailError {
                        case .awaitingSource, .staleSource, .superseded, .closed, .cancelled, .budgetUnavailable:
                            scheduleFilterRetry(id)
                        default: break
                        }
                    }
                }
            }
            InteractionTrace.shared.thumbnail(.terminal, kind: request.kind) {
                .init(reason: terminalReason, flags: [.cancelled: task.isCancelled || Task.isCancelled,
                    .scopeMatch: editing.developmentContext == context, .generationMatch: generation == request.registration.visibleGeneration],
                    numbers: [.visibleCount: Double(visible.count)], state: state(request.kind))
            }
            if let ready { await backend.releaseThumbnails(ready, registration: request.registration) }
            if let presentation { await backend.releaseThumbnails(presentation, registration: request.registration) }
            if !published {
                await backend.revokeThumbnails(request.registration)
                await backend.joinThumbnails(request.registration)
            }
            child = nil; active = nil; loading = []
        }
        // A cancelled operation still owns cleanup. Never skip it because Task.isCancelled.
        for old in retirements { await backend.releaseThumbnails(old.lease, registration: old.registration) }
        retirements = []
    }
}
