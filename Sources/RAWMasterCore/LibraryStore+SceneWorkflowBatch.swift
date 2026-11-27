import Foundation

extension LibraryStore {
    private static let templateAction = "sceneWorkflowTemplate.v1"
    private static let workflowBatchAction = "sceneWorkflowBatch.v1"
    private static let workflowItemAction = "sceneWorkflowItem.v1"

    package func sceneWorkflowTemplates() throws -> [SceneWorkflowTemplate] {
        try locked { try rows("SELECT data FROM editing_commands WHERE action=? ORDER BY rowid DESC", [Self.templateAction])
            .map { try decode($0[0], SceneWorkflowTemplate.self) } }
    }
    package func storeSceneWorkflowTemplate(_ template: SceneWorkflowTemplate) throws {
        try transaction {
            let key = Self.templateAction + "/" + template.id.uuidString, fingerprint = try EditingFingerprint.of(template)
            if let _: SceneWorkflowTemplate = try commandResult(id: key, fingerprint: fingerprint, action: Self.templateAction, type: SceneWorkflowTemplate.self) { return }
            try saveCommand(id: key, fingerprint: fingerprint, action: Self.templateAction, result: template)
        }
    }
    package func sceneWorkflowDonor(_ assetID: String) throws -> DevelopmentSceneGraphV1? {
        try withReadSnapshot {
            guard let source = try? sceneWorkflowSource(assetID), let work = try sceneWorkflowOwner(source) else { return nil }
            if let draft = work.liveRecipe { return draft.sceneGraph }
            return try editingVersion(id: work.adoptedVersionID).recipe.sceneGraph
        }
    }

    package func reviewSceneWorkflow(donorID: String, targets: [String], work: SceneWorkflowBatch.Work,
                                     basis: SceneWorkflowBatch.Basis) throws -> SceneWorkflowBatch.Review {
        guard !targets.isEmpty, targets.count <= SceneWorkflowBatch.maximumTargets,
              Set(targets).count == targets.count, !targets.contains(donorID) else { throw EditingError.invalidSource }
        return try withReadSnapshot {
            let donor = try asset(donorID)
            let header = SceneWorkflowBatch.Header(id: UUID(), createdAt: .now, donorAssetID: donorID, donorName: donor.filename,
                work: work, basis: basis, assetIDs: targets)
            let items = try targets.map { id -> SceneWorkflowBatch.Item in
                let file = try asset(id)
                guard file.resolvedURL.pathExtension.lowercased() == "arw" else {
                    return .init(id: id, name: file.filename, source: nil, head: nil, parent: nil, recipe: nil,
                        state: .incompatible, reason: "当前场景工作流不支持这种原片格式。")
                }
                guard let source = try? sceneWorkflowSource(id) else {
                    return .init(id: id, name: file.filename, source: nil, head: nil, parent: nil, recipe: nil,
                        state: .incompatible, reason: "没有可冻结的原片内容和准入身份。")
                }
                let owner = try sceneWorkflowOwner(source)
                let head = owner.map(SceneWorkflowBatch.Head.init)
                let parent = owner.map { basis == .original ? $0.originalVersionID : ($0.liveParentVersionID ?? $0.adoptedVersionID) }
                do {
                    var current: DevelopmentSceneGraphV1?
                    if basis == .current {
                        guard let owner, let parent else { throw EditingError.invalidRecipe }
                        let base = try editingVersion(id: parent)
                        guard try versionDisposition(versionID: parent) != .discarded else { throw EditingError.invalidParent }
                        current = (owner.liveRecipe ?? base.recipe).sceneGraph
                        guard current != nil else { throw EditingError.invalidRecipe }
                    }
                    let next = DevelopmentRecipe(sceneGraph: try work.result(on: current))
                    let available = file.availability == .available && FileManager.default.isReadableFile(atPath: file.resolvedURL.path)
                    return .init(id: id, name: file.filename, source: source, head: head, parent: parent, recipe: next,
                        state: available ? .pending : .offline, reason: available ? nil : "原片离线，接回同一内容后重试。")
                } catch {
                    return .init(id: id, name: file.filename, source: source, head: head, parent: parent, recipe: nil,
                        state: .incompatible, reason: basis == .current ? "没有兼容的场景底稿，或该图不能应用所选操作。" : "无法应用所选场景图或字段。")
                }
            }
            return .init(header: header, items: items)
        }
    }

    package func registerSceneWorkflow(_ review: SceneWorkflowBatch.Review) throws {
        let header = review.header, key = Self.workflowBatchKey(header.id)
        guard header.assetIDs == review.items.map(\.id), Set(header.assetIDs).count == header.assetIDs.count,
              !header.assetIDs.contains(header.donorAssetID), (1...SceneWorkflowBatch.maximumTargets).contains(header.assetIDs.count),
              review.items.allSatisfy({ [.pending, .offline, .incompatible].contains($0.state) && $0.candidate == nil && $0.committedHead == nil }) else { throw EditingError.invalidSource }
        try transaction {
            let fingerprint = try EditingFingerprint.of(review)
            if let _: SceneWorkflowBatch.Header = try commandResult(id: key, fingerprint: fingerprint, action: Self.workflowBatchAction, type: SceneWorkflowBatch.Header.self) { return }
            try saveCommand(id: key, fingerprint: fingerprint, action: Self.workflowBatchAction, result: header)
            for item in review.items { try saveCommand(id: Self.workflowItemKey(header.id, item.id), fingerprint: fingerprint, action: Self.workflowItemAction, result: item) }
        }
    }
    package func latestSceneWorkflow() throws -> SceneWorkflowBatch.Header? {
        try locked { try rows("SELECT data FROM editing_commands WHERE action=? ORDER BY rowid DESC LIMIT 1", [Self.workflowBatchAction])
            .first.map { try decode($0[0], SceneWorkflowBatch.Header.self) } }
    }
    package func sceneWorkflow(id: UUID) throws -> SceneWorkflowBatch.Review {
        try withReadSnapshot {
            let header = try sceneWorkflowHeader(id)
            return .init(header: header, items: try header.assetIDs.map { try sceneWorkflowItem(id, assetID: $0) })
        }
    }

    /// Decode/certify a source off the SQLite write lock, then atomically check the persisted pending item and target head.
    package func commitSceneWorkflowItem(_ batch: UUID, assetID: String, cancel: () throws -> Void = {},
                                         qualify: (EditingSourceSnapshot) throws -> Void) throws -> SceneWorkflowBatch.Item {
        var frozen = try sceneWorkflowItem(batch, assetID: assetID)
        guard frozen.state == .pending, let expected = frozen.source, let recipe = frozen.recipe else { return frozen }
        try cancel()
        let source: EditingSourceSnapshot
        let capturedStamp: FileStamp
        do {
            let asset = try locked { try self.asset(assetID) }
            guard asset.availability == .available else {
                return try failWorkflowPending(batch, assetID, state: asset.availability == .missing ? .offline : .conflict,
                    reason: "原片不可用或已变化。")
            }
            guard FileManager.default.isReadableFile(atPath: asset.resolvedURL.path) else {
                return try failWorkflowPending(batch, assetID, state: .offline, reason: "原片离线，接回后重试。")
            }
            capturedStamp = try FileSafety.stat(asset.resolvedURL)
            source = try captureEditingSourceSnapshot(assetID: assetID, cancel: cancel)
            guard source.hasSameIdentity(as: expected), capturedStamp == (try FileSafety.stat(source.sourceLocation)) else { throw EditingError.staleSource }
        } catch is CancellationError { throw CancellationError() }
        catch {
            return try failWorkflowPending(batch, assetID, state: .conflict, reason: "原片内容或纳入身份已变化。")
        }
        do { try qualify(source); try cancel() }
        catch is CancellationError { throw CancellationError() }
        catch { return try failWorkflowPending(batch, assetID, state: .incompatible, reason: "原片未通过场景线性解码及校准。") }
        return try transaction {
            frozen = try sceneWorkflowItem(batch, assetID: assetID)
            guard frozen.state == .pending else { return frozen } // cancellation won the write lock
            try cancel()
            let currentAsset = try asset(assetID)
            guard currentAsset.resolvedURL == source.sourceLocation, (try? FileSafety.stat(source.sourceLocation)) == capturedStamp,
                  (try? validateEditingSource(source)) != nil else {
                frozen.state = .conflict; frozen.reason = "原片在预检后变化。"
                try updateWorkflowItem(batch, frozen); return frozen
            }
            let active = try sceneWorkflowOwner(source)
            guard active.map(SceneWorkflowBatch.Head.init) == frozen.head else {
                frozen.state = .conflict; frozen.reason = "目标版本或草稿已在预检后修改。"
                try updateWorkflowItem(batch, frozen); return frozen
            }
            let owner = try active ?? createPhotoWork(source: source)
            let parent = frozen.parent ?? owner.originalVersionID
            guard try versionDisposition(versionID: parent) != .discarded else {
                frozen.state = .conflict; frozen.reason = "已冻结底稿已放弃。"
                try updateWorkflowItem(batch, frozen); return frozen
            }
            let version = try appendEditingVersion(.init(workID: owner.id, parentVersionID: parent, kind: .development,
                source: source, recipe: recipe, configuration: ["workflowBatch": batch.uuidString]))
            frozen.state = .completed; frozen.reason = nil; frozen.candidate = version.id; frozen.committedHead = .init(owner)
            try updateWorkflowItem(batch, frozen)
            return frozen
        }
    }

    package func cancelSceneWorkflow(_ batch: UUID) throws -> SceneWorkflowBatch.Review {
        try changeWorkflowItems(batch) { item in
            if item.state == .pending { item.state = .cancelled; item.reason = "已停止待处理项。" }
        }
    }
    package func retrySceneWorkflow(_ batch: UUID) throws -> SceneWorkflowBatch.Review {
        try changeWorkflowItems(batch) { item in
            if item.state.retryable, item.recipe != nil { item.state = .pending; item.reason = nil }
        }
    }
    package func undoSceneWorkflow(_ batch: UUID) throws -> SceneWorkflowBatch.Review {
        try changeWorkflowItems(batch) { item in
            guard item.state == .completed, let head = item.committedHead, let candidate = item.candidate else { return }
            let work = try photoWork(id: head.id)
            guard SceneWorkflowBatch.Head(work) == head, try versionDisposition(versionID: candidate) == .candidate,
                  work.liveParentVersionID != candidate else {
                item.state = .conflict; item.reason = "候选已被使用，或目标已有后续修订。"; return
            }
            do { try setVersionDisposition(versionID: candidate, disposition: .discarded) }
            catch EditingError.invalidParent {
                item.state = .conflict; item.reason = "另有版本或任务依赖此候选。"; return
            }
            item.state = .undone; item.reason = nil
        }
    }

    private func sceneWorkflowOwner(_ source: EditingSourceSnapshot) throws -> PhotoWork? {
        try loadPhotoWorks(projectID: source.projectID, assetID: source.assetID).last { $0.source.hasSameIdentity(as: source) }
    }
    private static func workflowBatchKey(_ id: UUID) -> String { workflowBatchAction + "/" + id.uuidString }
    private static func workflowItemKey(_ id: UUID, _ asset: String) -> String { workflowItemAction + "/" + id.uuidString + "/" + asset }
    private func sceneWorkflowHeader(_ id: UUID) throws -> SceneWorkflowBatch.Header {
        guard let data = try rows("SELECT data FROM editing_commands WHERE id=? AND action=?", [Self.workflowBatchKey(id), Self.workflowBatchAction]).first?.first else { throw EditingError.missingWork }
        return try decode(data, SceneWorkflowBatch.Header.self)
    }
    private func sceneWorkflowItem(_ id: UUID, assetID: String) throws -> SceneWorkflowBatch.Item {
        try locked {
            guard let data = try rows("SELECT data FROM editing_commands WHERE id=? AND action=?", [Self.workflowItemKey(id, assetID), Self.workflowItemAction]).first?.first else { throw EditingError.missingWork }
            return try decode(data, SceneWorkflowBatch.Item.self)
        }
    }
    private func updateWorkflowItem(_ batch: UUID, _ item: SceneWorkflowBatch.Item) throws {
        try statement("UPDATE editing_commands SET data=? WHERE id=? AND action=?", [try json(item), Self.workflowItemKey(batch, item.id), Self.workflowItemAction])
    }
    private func failWorkflowPending(_ batch: UUID, _ assetID: String, state: SceneWorkflowBatch.State, reason: String) throws -> SceneWorkflowBatch.Item {
        try transaction {
            var item = try sceneWorkflowItem(batch, assetID: assetID)
            if item.state == .pending { item.state = state; item.reason = reason; try updateWorkflowItem(batch, item) }
            return item
        }
    }
    private func changeWorkflowItems(_ batch: UUID, _ edit: (inout SceneWorkflowBatch.Item) throws -> Void) throws -> SceneWorkflowBatch.Review {
        try transaction {
            let header = try sceneWorkflowHeader(batch)
            let items = try header.assetIDs.map { id -> SceneWorkflowBatch.Item in
                let original = try sceneWorkflowItem(batch, assetID: id)
                var item = original; try edit(&item)
                if item != original { try updateWorkflowItem(batch, item) }
                return item
            }
            return .init(header: header, items: items)
        }
    }
}
