import Foundation

public enum GroupCommandRequest: Codable, Sendable {
  case create(assetIDs: [String], name: String, kind: String)
  case rename(groupID: String, name: String)
  case setKind(groupID: String, kind: String)
  case setLocked(groupID: String, locked: Bool)
  case removeMembers(groupID: String, assetIDs: [String])
  case reorder(groupID: String, assetIDs: [String])
  case setParticipation(groupIDs: [String], assetIDs: [String], included: Bool)
  case merge(groupIDs: [String], name: String, kind: String)
  case split(groupID: String, movedAssetIDs: [String], newName: String, newKind: String)
  case restore(commandID: String)
  case automaticBatch(AutomaticGroupingBatch)
}
public enum GroupTouchDomain: Codable, Sendable, Hashable {
  case existence, all, name, kind, lock
  case member(assetID: String)
  var key: String {
    switch self {
    case .existence: return "existence"
    case .all: return "all"
    case .name: return "name"
    case .kind: return "kind"
    case .lock: return "lock"
    case .member(let id): return "member:" + id
    }
  }
  init(key: String) throws {
    switch key {
    case "existence": self = .existence
    case "all": self = .all
    case "name": self = .name
    case "kind": self = .kind
    case "lock": self = .lock
    default:
      guard key.hasPrefix("member:") else { throw LibraryError.invalid("未知组域") }
      self = .member(assetID: String(key.dropFirst(7)))
    }
  }
}
public struct GroupDomainVersion: Codable, Sendable {
  public var groupID: String
  public var domain: GroupTouchDomain
  public var revision: Int
  public var logicalWriterID: String?
  public var lastOperationID: String?
  public init(
    groupID: String, domain: GroupTouchDomain, revision: Int = 0, logicalWriterID: String? = nil,
    lastOperationID: String? = nil
  ) {
    self.groupID = groupID
    self.domain = domain
    self.revision = revision
    self.logicalWriterID = logicalWriterID
    self.lastOperationID = lastOperationID
  }
}
public struct GroupParticipationValue: Codable, Sendable {
  public var groupID: String
  public var included: Bool
  public init(groupID: String, included: Bool) {
    self.groupID = groupID
    self.included = included
  }
}
public struct GroupParticipationConflict: Codable, Sendable, Identifiable {
  public var id: String { assetID }
  public var assetID: String
  public var values: [GroupParticipationValue]
  public init(assetID: String, values: [GroupParticipationValue]) {
    self.assetID = assetID
    self.values = values
  }
}
public struct GroupCommandPreview: Codable, Sendable, Identifiable {
  public var id: String
  public var request: GroupCommandRequest
  public var before: [CaptureGroup]
  public var after: [CaptureGroup]
  public var inclusionConflicts: [GroupParticipationConflict]
  public var warnings: [String]
  public var dependencies: [GroupDomainVersion]
  public init(
    id: String = UUID().uuidString, request: GroupCommandRequest, before: [CaptureGroup] = [],
    after: [CaptureGroup] = [], inclusionConflicts: [GroupParticipationConflict] = [],
    warnings: [String] = [], dependencies: [GroupDomainVersion] = []
  ) {
    self.id = id
    self.request = request
    self.before = before
    self.after = after
    self.inclusionConflicts = inclusionConflicts
    self.warnings = warnings
    self.dependencies = dependencies
  }
}
public enum GroupRestoreStatus: Codable, Sendable {
  case available, alreadyReverted
  case conflict(reason: String)
}
public struct GroupCommandRecord: Codable, Sendable, Identifiable {
  public var id: String
  public var payloadVersion: Int
  public var request: GroupCommandRequest
  public var createdAt: Date
  public var before: [CaptureGroup]
  public var after: [CaptureGroup]
  public var beforeDomains: [GroupDomainVersion]
  public var afterDomains: [GroupDomainVersion]
  public var compensates: String?
  public var compensationIDs: [String]
  public var restoreStatus: GroupRestoreStatus
  public init(
    id: String, payloadVersion: Int = 1, request: GroupCommandRequest, createdAt: Date = Date(),
    before: [CaptureGroup], after: [CaptureGroup], beforeDomains: [GroupDomainVersion],
    afterDomains: [GroupDomainVersion], compensates: String? = nil, compensationIDs: [String] = [],
    restoreStatus: GroupRestoreStatus = .available
  ) {
    self.id = id
    self.payloadVersion = payloadVersion
    self.request = request
    self.createdAt = createdAt
    self.before = before
    self.after = after
    self.beforeDomains = beforeDomains
    self.afterDomains = afterDomains
    self.compensates = compensates
    self.compensationIDs = compensationIDs
    self.restoreStatus = restoreStatus
  }
}

struct GroupCommandEnvelope: Codable {
  var record: GroupCommandRecord
  var requestDigest: String
  var choices: [String: Bool]
}
struct GroupMemberState: Codable, Equatable {
  var position: Int
  var included: Bool
}
extension CaptureGroup {
  var memberStates: [String: GroupMemberState] {
    Dictionary(
      uniqueKeysWithValues: assetIDs.enumerated().map {
        (
          $0.element,
          GroupMemberState(position: $0.offset, included: includedAssetIDs.contains($0.element))
        )
      })
  }
}
struct GroupDelta {
  var id: String
  var before: CaptureGroup?
  var after: CaptureGroup?
  var domains: Set<GroupTouchDomain>
  static func differences(_ before: CaptureGroup?, _ after: CaptureGroup?, id: String) -> GroupDelta
  {
    var domains = Set<GroupTouchDomain>()
    if (before == nil) != (after == nil) { domains.formUnion([.existence, .name, .kind, .lock]) }
    if before?.name != after?.name { domains.insert(.name) }
    if before?.kind != after?.kind { domains.insert(.kind) }
    if before?.locked != after?.locked { domains.insert(.lock) }
    let b = before?.memberStates ?? [:]
    let a = after?.memberStates ?? [:]
    for member in Set(b.keys).union(a.keys) where b[member] != a[member] {
      domains.insert(.member(assetID: member))
    }
    return GroupDelta(id: id, before: before, after: after, domains: domains)
  }
}
