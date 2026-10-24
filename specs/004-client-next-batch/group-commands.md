# B1 组命令实现合同

2026-10-23 · **Approved implementation contract**。以下为冻结接口与语义，实际完成状态见 validation.md。用户批准 A → B；根据 SC05，当前实现完整 B1，B2 只记录独立诊断与证据缺口，正式候选工作流延期。

## Ownership and migration

- Core owns domain records, command previews/transactions, group restore and migration. Files: `Models.swift`, `DatabaseSchema.swift`, `LibraryStore.swift`, new `GroupCommands.swift`, `LibraryStore+GroupCommands.swift`; Core tests owned by the same lane. No production AssetRecord metadata fields are added.
- Imaging depends on Core, never the reverse. Imaging may own independent diagnostic-only EXIF/time/feature experiments and their temporary types/JSON. They do not require this batch to expand Core. Core never asks Imaging to decode or analyze.
- UI owns command/impact review, duplicate participation choices, runtime undo order, existing and new group review/corrections. Root owns orchestration, evidence and real sample evaluation.
- One explicit **v2→v3** migration creates only `group_commands(id,data)` and `group_domains(group_id,domain,revision,logical_writer_id,last_operation_id,tombstoned)` (primary key group_id+domain). Group-domain rows survive formal-group deletion as tombstones; no unused suggestion tables. v1→v3 runs v1→v2 and v2→v3 in one transaction following the existing single consistent pre-upgrade backup. A failure leaves the original version and state intact. Unknown newer versions/objects still reject before writes.
- v2 groups remain manual/locked and keep membership/order. Seed group-domain counters from group state; no invented prior undo history. B1 logs commands only after upgrade, retains older operations as read-only audit. JSON new fields decode with explicit defaults.

## B1 public domain/API

All records are Codable/Sendable, records with IDs are Identifiable, and have public initializers. Existing `CaptureGroup` fields `origin`, `locked`, `groupRevision`, `assetIDs` and `includedAssetIDs` remain. `kind:String` preserves custom/legacy purposes; UI offers unknown/burst/timelapse/HDR/astrophotography/other labels. A snapshot's assetIDs order is authoritative; includedAssetIDs is its participation subset.

```swift
public enum GroupCommandRequest: Codable, Sendable {
  case create(assetIDs:[String], name:String, kind:String)
  case rename(groupID:String, name:String)
  case setKind(groupID:String, kind:String)
  case setLocked(groupID:String, locked:Bool)
  case removeMembers(groupID:String, assetIDs:[String])
  case reorder(groupID:String, assetIDs:[String])
  case setParticipation(groupIDs:[String], assetIDs:[String], included:Bool)
  case merge(groupIDs:[String], name:String, kind:String)
  case split(groupID:String, movedAssetIDs:[String], newName:String, newKind:String)
  case restore(commandID:String)
}
public enum GroupTouchDomain: Codable, Sendable {
  case existence, all, name, kind, lock, member(assetID:String)
}
public struct GroupDomainVersion: Codable, Sendable {
  public var groupID:String; public var domain:GroupTouchDomain
  public var revision:Int // physical revision; monotonic, never reset
  public var logicalWriterID:String?; public var lastOperationID:String?
}
public struct GroupParticipationValue: Codable, Sendable {
  public var groupID:String; public var included:Bool
}
public struct GroupParticipationConflict: Codable, Sendable, Identifiable {
  public var id:String // assetID
  public var assetID:String; public var values:[GroupParticipationValue]
}
public struct GroupCommandPreview: Codable, Sendable, Identifiable {
  public var id:String; public var request:GroupCommandRequest
  public var before:[CaptureGroup]; public var after:[CaptureGroup]
  public var inclusionConflicts:[GroupParticipationConflict]
  public var warnings:[String]; public var dependencies:[GroupDomainVersion]
}
public enum GroupRestoreStatus: Codable, Sendable { case available, alreadyReverted, conflict(reason:String) }
public struct GroupCommandRecord: Codable, Sendable, Identifiable {
  public var id:String; public var payloadVersion:Int // 1
  public var request:GroupCommandRequest; public var createdAt:Date
  public var before:[CaptureGroup]; public var after:[CaptureGroup]
  public var beforeDomains:[GroupDomainVersion]; public var afterDomains:[GroupDomainVersion]
  public var compensates:String?; public var compensationIDs:[String] // audit lineage, not eligibility
  public var restoreStatus:GroupRestoreStatus // recomputed on load, never trusted at commit
}
extension LibraryStore {
  public func previewGroupCommand(_ request:GroupCommandRequest) throws -> GroupCommandPreview
  public func commitGroupCommand(_ preview:GroupCommandPreview,
      participationResolutions:[String:Bool] = [:]) throws -> GroupCommandRecord
  public func undoGroupCommand(id:String, requestID:String = UUID().uuidString) throws -> GroupCommandRecord
  public func loadGroupCommands(limit:Int = 50) throws -> [GroupCommandRecord]
}
```

Behavior frozen for implementation:

1. Preview reads only; never creates formal groups. New group IDs are deterministic: `group-` + full hex SHA256 of the canonical JSON tuple `["RAWMaster.group.v1", preview.id, role]`, where role is `create:0`, `merge:0` or `split:0`. Restorations reuse the audited original identity. Commit derives these IDs itself, never consumes IDs or writable state from preview.after. Missing/duplicate/foreign-project members and malformed reorder/split fail explicitly. Split removes the chosen members from the old group, preserving their relative order and inclusion in the new group; both nonempty sides are required. `create` and the merged result must be nonempty. Explicitly removing all members keeps the named empty locked group and adds an impact warning; it does not silently delete it. A merge requires at least two groups and can absorb an existing empty group if the result is nonempty. Blank names and repeated input IDs fail.
2. Merge reports **every shared asset whose included flags differ**, listing its source groups/values. Commit requires one explicit Boolean resolution for each conflict, accepts no irrelevant resolution IDs, and never defaults to OR. Preview may show unresolved after-state with conflict markers; it is not authoritative until resolutions are supplied.
3. Commit revalidates the request, scope and touched-domain dependencies; it does not trust mutated client snapshots. State, membership, domain counters, minimal before/after patch, operation and command record commit in one SQLite transaction. Repeated commit of the same preview ID returns the original record only when its normalized request AND resolved participation choices equal the recorded digests; a different target/request/choice fails. Canonical normalization trims names/kinds, sorts set-like member/group inputs where order has no meaning, preserves meaningful create/reorder/merge group order, and rejects duplicate IDs. Canonical choices use sorted asset-ID keys. Before/after snapshots are display-only; commit rederives the request from the database, validates all required and supplied dependencies, and computes its own patch.
4. Manual structural/member edits lock affected groups by default; `setLocked(false)` is the explicit exception. A locked group allows manual correction. Existing `createGroup`/rename/remove/merge/reorder/participation methods delegate to this path; unresolved legacy merge now throws and UI uses preview+resolution. For global `setSequenceMembership(...groupID:nil)`, one `setParticipation(groupIDs:...)` command spans the actual affected groups, so undo matches the single UI action. It modifies only memberships that actually exist in those groups; every input asset must occur in at least one named group and every named group must contain at least one selected asset. All affected groups belong to one project. Tombstone and active-state changes across all groups/members are atomic with the command/audit rows. Deleted group IDs are not recycled for unrelated groups; restoration of the same identity is explicit.
5. Snapshots support impact review/audit, but compensation applies only the **actual changed fields/member domains**. It never restores an AssetRecord or its ratings/decisions. Reorder touches changed position domains. Removing/recreating a whole group claims its `all`/existence domain. Domain revisions, rather than asset revision, validate group changes.
6. Repeated undo must work. Persist monotonic physical domain revisions **and logical writer heads**, with lastOperationID retaining every newest compensation ID even when the logical head points back. GroupCommandRecord keeps before/after domain heads and physical revisions. A forward edit sets the head to its command; compensation checks current after-value/head and restores the recorded previous logical head while increasing physical revision. An unrelated rating or untouched group member does not conflict. Later same-domain ABA edits do conflict; an audited compensation may expose the prior command for the next undo. Full-group deletion/restoration uses the history-aware aggregate below; compensation of a fine domain MUST NOT rewind an aggregate head to the target command’s old head.
7. `restore(commandID:)` supplies a normal impact preview for recent-history UI; `undoGroupCommand` is the convenience preview+commit for active ⌘Z. Compensation never runs forward-command auto-lock behavior: it applies only the exact inverse patch, including a lock inverse only if that lock field was actually changed by the original command. Every user restore intent receives a stable request/preview ID. Retrying that ID returns the same compensation (and validates the same target/choices); it never applies twice. A new request cannot apply an already reverted target, but may restore a target made current again by a later audited inverse. Persisted command rows retain all compensation links; these links alone do not determine present eligibility.
8. UI keeps one runtime stack: `.selection([SelectionChange])` / `.group(commandID:String)` in actual action order. Successful keyboard undo pops its entry without pushing the compensation back; an explicit recent-history restoration is a new user action and may be pushed. Restart exposes persistent group history only, without claiming a persisted selection stack or arbitrary full redo UI.

## Concrete aggregate/existence mechanism

- Each actual mutation increments `all.revision` and sets `all.last_operation_id` to its newest forward/compensation command. Fine-domain mutations additionally increment their own physical revisions and set their newest physical operation IDs. All rows survive deletion; deleted groups are tombstoned. No counter is decremented by restoration. CaptureGroup.groupRevision mirrors the current physical aggregate revision; snapshots never copy it backward, and the logical-state digest excludes physical counters/last-operation audit fields.
- Fine-domain logical heads represent the current **audited causal effect**. Forward edit: set touched fine head to this command ID. Compensation: restore its recorded prior fine head and value, but retain the compensation as `last_operation_id` and in command lineage. Unrelated fine domains are not assigned or rewound.
- The `.all.logicalWriterID` field holds an opaque **aggregate logical-state digest**, not a last-command pointer. Recompute from canonical current existence + existence logical head + group field values/heads + sorted member presence/position/inclusion/heads. Include absent-member tombstones with a non-nil logical head, to detect un-compensated add/remove ABA; omit absent-member rows whose logical head returned to nil. For an absent group, the digest is its absent-existence value/head; retained fine rows remain tombstoned audit and cannot be actively edited.
- Every forward preview that deletes/replaces a whole group captures `.all` physical revision/digest and `.existence`; commit checks both. Thus **any** intervening name/kind/lock/member write invalidates such a preview, even if the visible values returned to their earlier state. A fine-domain command depends on existence plus relevant fine domains, not `.all`, so a later independent member change does not block name restoration.
- A restore preview checks the target’s expected after-values/heads for its actual touched fine domains; whole-group inverse actions check the stored after aggregate digest/existence. It then captures *current* physical revisions for CAS at commit. An arbitrary later same-domain ABA has different fine heads, so fails. Audited sequential undo restores the earlier fine vector, so its recomputed aggregate digest can again equal the prior whole-group command’s after digest even though all physical revisions increased.
- Example: create C → rename R → member edit M → restore R updates only name (and an originally changed lock, if applicable). M’s member values/head remain and the aggregate still includes M. Whole-group C restoration stays blocked. After restoring M, fine heads/values return to C’s audited after-state and C may be restored. No aggregate pointer is simply assigned R’s old value. Another required sequence is whole-group operation → later edits → their chronological audited compensation → whole-group compensation.
- Existence is hierarchical: every active-group command requires the current existence head/presence; whole-group removal/restore claims aggregate/existence plus the concrete membership/field patch. Multi-group merge/split/compensation, all associated tombstones, membership rows, domains, command and operation log change in one transaction. Restore retry reuses the same request ID; a new inverse-of-compensation action has a new request ID and remains independently undoable.


## B2 boundary after SC05 review

B2 production scope is **deferred**. The current labeled 123-frame burst is a positive development/functional fixture; it is not an independent held-out dataset or negative-boundary evidence. This release implements complete B1 and records the B2 evidence gap. It does not expose a production suggestion workflow or persist candidate/run states.

Imaging may implement a separate diagnostic experiment with temporary EXIF/time/feature/proposal types and JSON output. It preserves raw EXIF strings, treats local civil time separately from UTC, requires valid explicit offset for UTC, never treats model name as a device identity, and never writes user decisions or production metadata. Core gains no production metadata fields, suggestion models, suggestion tables, or Imaging dependency in this batch. Any later production promotion needs the missing evaluation and a new contract review.

## Required B1 tests before acceptance

Each command and compensation; repeated chronological ⌘Z across selections/group commands; explicit recent-history restore pushed to runtime stack and itself undone; rename restore after independent membership edits; same-domain ABA conflict; later ratings survive member restoration; explicit merge participation choices; split/merge round trip; empty-split rejection; delete-preview then any group-field change rejection; aggregate sequencing/independent-member preservation; lock persistence; cross-project rejection; compensation retry idempotence by request ID; multi-group rollback/tombstones; v1→v3 and v2→v3 consistent-backup/failure/reopen. No B2 quality acceptance is implied.

## 实施后的样本补充

本合同冻结后，用户补充独立的 DSC01497–DSC01510 组，并确认 DSC01496、DSC01511 均在组外。固定规则首读结果和溯源限制见 [validation.md](validation.md)；尚未形成通过 SC04 的生产时间加视觉规则，因此 B2 正式入口仍延期。上文缺样本描述保留为合同冻结时背景，不代表当前没有这些新标注。
