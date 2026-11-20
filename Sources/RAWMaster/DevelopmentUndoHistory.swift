import Foundation
import RAWMasterCore

struct EditingDraftBranchID: Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct DevelopmentHistoryKey: Hashable {
    let workID: String
    let admissionFingerprint: String
    let sourceContentID: String
    let branchID: EditingDraftBranchID
}

/// Recipe metadata only. Cost deliberately double-counts shared value storage; no pixels or patch bytes
/// are retained here. The ledger is independent of the renderer's image-cache budget.
struct DevelopmentUndoHistory {
    struct Limits {
        var entriesPerBranch = 64
        var bytesPerBranch = 32 * 1024 * 1024
        var totalBytes = 64 * 1024 * 1024
        var branches = 8
        init(entriesPerBranch: Int = 64, bytesPerBranch: Int = 32 * 1024 * 1024,
             totalBytes: Int = 64 * 1024 * 1024, branches: Int = 8) {
            self.entriesPerBranch = max(0, min(64, entriesPerBranch))
            self.bytesPerBranch = max(0, min(32 * 1024 * 1024, bytesPerBranch))
            self.totalBytes = max(0, min(64 * 1024 * 1024, totalBytes))
            self.branches = max(1, min(8, branches))
        }
    }
    struct Entry {
        let before: DevelopmentRecipe
        let after: DevelopmentRecipe
        let beforeUI: DevelopmentSummaryUIState
        let afterUI: DevelopmentSummaryUIState
        let title: String
        let cost: Int
    }
    private final class SummaryEndpoint {
        let ui: DevelopmentSummaryUIState
        let fingerprint: String
        init?(ui: DevelopmentSummaryUIState, recipe: DevelopmentRecipe) {
            let validated = ui.validating(for: recipe)
            guard !validated.isEmpty, let fingerprint = try? EditingFingerprint.of(recipe) else { return nil }
            self.ui = validated; self.fingerprint = fingerprint
        }
    }
    private struct Branch {
        var entries: [Entry] = []
        var cursor = 0
        var cost = 0
        var access: UInt64 = 0
        // Absent metadata owns no allocated endpoint. A present immutable endpoint is billed
        // conservatively, including its fixed SHA when no recipe history entry exists.
        var summaryEndpoint: SummaryEndpoint?
        var endpointCost: Int { summaryEndpoint == nil ? 0 : DevelopmentSummaryUIState.conservativeCost }
    }
    let limits: Limits
    private var branches: [DevelopmentHistoryKey: Branch] = [:]
    private(set) var activeKey: DevelopmentHistoryKey?
    private var clock: UInt64 = 0
    init(limits: Limits = .init()) { self.limits = limits }

    var totalCost: Int { branches.values.reduce(0) { $0 + $1.cost + $1.endpointCost } }
    var branchCount: Int { branches.count }
    var entryCount: Int { activeKey.flatMap { branches[$0]?.entries.count } ?? 0 }
    var canUndo: Bool { activeKey.flatMap { branches[$0]?.cursor }.map { $0 > 0 } ?? false }
    var canRedo: Bool {
        guard let key = activeKey, let branch = branches[key] else { return false }
        return branch.cursor < branch.entries.count
    }
    var undoTitle: String? {
        guard let key = activeKey, let branch = branches[key], branch.cursor > 0 else { return nil }
        return branch.entries[branch.cursor - 1].title
    }
    var redoTitle: String? {
        guard let key = activeKey, let branch = branches[key], branch.cursor < branch.entries.count else { return nil }
        return branch.entries[branch.cursor].title
    }

    mutating func activate(_ key: DevelopmentHistoryKey, current: DevelopmentRecipe) {
        clock &+= 1; activeKey = key
        var branch = branches[key] ?? .init()
        if let expected = endpoint(branch), expected != current { branch = .init() }
        let fingerprint = try? EditingFingerprint.of(current)
        if branch.summaryEndpoint?.fingerprint != fingerprint { branch.summaryEndpoint = nil }
        if let ui = branch.summaryEndpoint?.ui { branch.summaryEndpoint = .init(ui: ui, recipe: current) }
        branch.access = clock; branches[key] = branch; trim()
    }
    mutating func deactivate() { activeKey = nil }
    mutating func clearActive() {
        guard let key = activeKey else { return }
        branches[key] = Branch(access: clock)
    }
    mutating func record(before: DevelopmentRecipe, after: DevelopmentRecipe, title: String,
                         beforeUI: DevelopmentSummaryUIState = .init(), afterUI: DevelopmentSummaryUIState = .init()) {
        guard before != after else { updateCurrentUI(afterUI, current: after); return }
        guard let key = activeKey else { return }
        var branch = branches[key] ?? .init()
        if let expected = endpoint(branch), expected != before { branch = .init() }
        if branch.cursor < branch.entries.count {
            branch.entries.removeSubrange(branch.cursor...)
            branch.cost = branch.entries.reduce(0) { $0 + $1.cost }
        }
        let entry = Entry(before: before, after: after, beforeUI: beforeUI.validating(for: before), afterUI: afterUI.validating(for: after),
                          title: String(title.prefix(128)),
                          cost: Self.metadataCost(before) + Self.metadataCost(after) + 1024 + DevelopmentSummaryUIState.conservativeCost)
        branch.summaryEndpoint = .init(ui: entry.afterUI, recipe: after)
        // An oversized edit remains the current draft. It does not escape the history budget.
        if limits.entriesPerBranch == 0 || entry.cost > min(limits.bytesPerBranch, limits.totalBytes) {
            branch.entries = []; branch.cursor = 0; branch.cost = 0
        } else {
            branch.entries.append(entry); branch.cursor = branch.entries.count; branch.cost += entry.cost
            while !branch.entries.isEmpty && (branch.entries.count > limits.entriesPerBranch || branch.cost + branch.endpointCost > limits.bytesPerBranch) {
                branch.cost -= branch.entries.removeFirst().cost; branch.cursor -= 1
            }
        }
        if branch.endpointCost > limits.bytesPerBranch { branch.summaryEndpoint = nil }
        clock &+= 1; branch.access = clock; branches[key] = branch; trim()
    }
    func currentUI(current: DevelopmentRecipe) -> DevelopmentSummaryUIState {
        guard let key = activeKey, let branch = branches[key],
              let endpoint = branch.summaryEndpoint, endpoint.fingerprint == (try? EditingFingerprint.of(current)) else { return .init() }
        return endpoint.ui.validating(for: current)
    }
    /// UI-only no-op updates affect the current endpoint, never an immutable entry snapshot.
    mutating func updateCurrentUI(_ state: DevelopmentSummaryUIState, current: DevelopmentRecipe) {
        guard let key = activeKey else { return }
        var branch = branches[key] ?? .init()
        if let expected = endpoint(branch), expected != current { return }
        branch.summaryEndpoint = .init(ui: state, recipe: current)
        if branch.endpointCost > limits.bytesPerBranch { branch.summaryEndpoint = nil }
        clock &+= 1; branch.access = clock; branches[key] = branch; trim()
    }
    func undoCandidate(current: DevelopmentRecipe) -> DevelopmentRecipe? {
        guard let key = activeKey, let branch = branches[key], branch.cursor > 0,
              endpoint(branch) == current else { return nil }
        return branch.entries[branch.cursor - 1].before
    }
    func redoCandidate(current: DevelopmentRecipe) -> DevelopmentRecipe? {
        guard let key = activeKey, let branch = branches[key], branch.cursor < branch.entries.count,
              endpoint(branch) == current else { return nil }
        return branch.entries[branch.cursor].after
    }
    mutating func didUndo() {
        guard let key = activeKey, var branch = branches[key], branch.cursor > 0 else { return }
        let entry = branch.entries[branch.cursor - 1]
        branch.summaryEndpoint = .init(ui: entry.beforeUI, recipe: entry.before)
        branch.cursor -= 1; clock &+= 1; branch.access = clock; branches[key] = branch; trim()
    }
    mutating func didRedo() {
        guard let key = activeKey, var branch = branches[key], branch.cursor < branch.entries.count else { return }
        let entry = branch.entries[branch.cursor]
        branch.summaryEndpoint = .init(ui: entry.afterUI, recipe: entry.after)
        branch.cursor += 1; clock &+= 1; branch.access = clock; branches[key] = branch; trim()
    }
    private func endpoint(_ branch: Branch) -> DevelopmentRecipe? {
        if branch.cursor > 0 { return branch.entries[branch.cursor - 1].after }
        return branch.entries.first?.before
    }
    private mutating func trim() {
        while branches.count > limits.branches || totalCost > limits.totalBytes
            || activeKey.flatMap({ branches[$0] }).map({ $0.cost + $0.endpointCost > limits.bytesPerBranch }) == true {
            if let oldest = branches.filter({ $0.key != activeKey }).min(by: { $0.value.access < $1.value.access })?.key {
                branches.removeValue(forKey: oldest)
            } else if let key = activeKey, var branch = branches[key], !branch.entries.isEmpty {
                // Under a small total budget, keep the contiguous endpoint around the active cursor.
                if branch.cursor > 0 { branch.cost -= branch.entries.removeFirst().cost; branch.cursor -= 1 }
                else { branch.cost -= branch.entries.removeLast().cost }
                branches[key] = branch
            } else if let key = activeKey, var branch = branches[key], branch.summaryEndpoint != nil {
                branch.summaryEndpoint = nil; branches[key] = branch
            } else { break }
        }
    }
    static func metadataCost(_ recipe: DevelopmentRecipe) -> Int {
        // Fixed fields/enums/containers, then conservative per-element storage and reference strings.
        var result = 16 * 1024
        func curvesCost(_ curves: DevelopmentCurves) -> Int {
            [curves.rgb, curves.red, curves.green, curves.blue].reduce(0) { $0 + $1.points.count * 128 }
        }
        if let color = recipe.color { result += curvesCost(color.curves) }
        if let p = recipe.adjustmentsV3 {
            if let color = p.legacyBasis?.color { result += curvesCost(color.curves) }
            result += [p.curves.rgb, p.curves.red, p.curves.green, p.curves.blue]
                .reduce(0) { $0 + $1.curve.points.count * 128 }
            for operation in p.localEdits.operations {
                result += 2048 + operation.stroke.points.count * 128
                // Patch is only a small immutable reference, never the content or declared byteCount.
                result += operation.sourceContentID.utf8.count * 4 + (operation.patch?.sha256.utf8.count ?? 0) * 4
            }
        }
        return result
    }
}
