import Foundation

package struct SceneWorkflowTemplate: Codable, Equatable, Identifiable, Sendable {
    package enum Kind: String, Codable, Sendable { case whole, group }
    package let id: UUID
    package let name: String
    package let kind: Kind
    package let scope: DevelopmentSceneGraphV1.Scope

    package init(name: String, kind: Kind, scope: DevelopmentSceneGraphV1.Scope, id: UUID = UUID()) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 180 else { throw EditingError.invalidRecipe }
        _ = try DevelopmentSceneGraphV1(graph: scope, output: .init(sdrTrim: Self.neutralTrim))
        self.id = id; self.name = title; self.kind = kind; self.scope = scope
    }
    private enum CodingKeys: String, CodingKey { case id, name, kind, scope }
    package init(from decoder: Decoder) throws {
        try RecipeCoding.requireKeys(decoder, ["id", "name", "kind", "scope"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: fields.decode(String.self, forKey: .name), kind: fields.decode(Kind.self, forKey: .kind),
                      scope: fields.decode(DevelopmentSceneGraphV1.Scope.self, forKey: .scope), id: fields.decode(UUID.self, forKey: .id))
    }
    static let neutralTrim = try! DevelopmentSceneOutputStateV1.SDRTrim(exposureEV: 0, mapping: .balanced, highlightCompression: 0)

    package func applying(to target: DevelopmentSceneGraphV1?, at path: [UUID] = [], edge: DevelopmentSceneGraphV1.Edge? = nil) throws -> DevelopmentSceneGraphV1 {
        let output = target?.output ?? .init(sdrTrim: Self.neutralTrim)
        let donor = try DevelopmentSceneGraphV1(graph: scope, output: output)
        if kind == .whole {
            guard path.isEmpty, edge == nil else { throw DevelopmentSceneGraphV1.Failure.ambiguousBoundary }
            return try donor.remapped()
        }
        let base = try target ?? DevelopmentSceneGraphV1(graph: .init(nodes: [], output: .input), output: output)
        guard let location = base.scope(at: path) else { throw DevelopmentSceneGraphV1.Failure.ambiguousBoundary }
        return try base.insertingTemplate(donor, on: edge ?? .init(.final, upstream: location.output), at: path, name: name)
    }
}

package enum SceneWorkflowBatch {
    package static let maximumTargets = 200
    package enum Basis: String, CaseIterable, Codable, Sendable { case current, original }
    package enum State: String, Codable, Sendable {
        case pending, offline, incompatible, conflict, completed, cancelled, undone, failed
        package var retryable: Bool { self == .offline || self == .cancelled || self == .failed }
    }
    package enum Work: Codable, Equatable, Sendable {
        case apply(SceneWorkflowTemplate)
        case exposure(Float)

        package func result(on base: DevelopmentSceneGraphV1?) throws -> DevelopmentSceneGraphV1 {
            switch self {
            case .apply(let template): return try template.applying(to: base)
            case .exposure(let value):
                if let base {
                    guard let node = base.graph.nodes.first(where: { if case .corrector = $0.operation { return true }; return false }) else {
                        throw EditingError.invalidRecipe
                    }
                    return try base.updating(node.id, at: []) {
                        guard case let .corrector(image, mask, _, curve, strength, enabled) = $0.operation else { throw EditingError.invalidRecipe }
                        return .init(id: $0.id, name: $0.name, operation: .corrector(image: image, mask: mask,
                            exposureEV: value, curve: curve, strength: strength, enabled: enabled))
                    }
                }
                let corrector = DevelopmentSceneGraphV1.Node(name: "批量曝光", operation: .corrector(image: .input, mask: nil,
                    exposureEV: value, curve: [], strength: 1, enabled: true))
                return try .init(graph: .init(nodes: [corrector], output: .node(corrector.id)), output: .init(sdrTrim: SceneWorkflowTemplate.neutralTrim))
            }
        }
    }
    package struct Header: Codable, Equatable, Identifiable, Sendable {
        package let id: UUID
        package let createdAt: Date
        package let donorAssetID: String
        package let donorName: String
        package let work: Work
        package let basis: Basis
        package let assetIDs: [String]
    }
    // ABA fence for the target as it existed at review. The candidate never replaces these values.
    struct Head: Codable, Equatable, Sendable {
        let id: String
        let adopted: String
        let adoptionRevision: Int
        let liveParent: String?
        let liveRevision: Int?
        init(_ work: PhotoWork) {
            id = work.id; adopted = work.adoptedVersionID; adoptionRevision = work.adoptionRevision
            liveParent = work.liveParentVersionID; liveRevision = work.liveRevision
        }
    }
    package struct Item: Codable, Equatable, Identifiable, Sendable {
        package let id: String
        package let name: String
        package let source: EditingSourceSnapshot?
        let head: Head?
        package let parent: String?
        package let recipe: DevelopmentRecipe?
        package internal(set) var state: State
        package internal(set) var reason: String?
        package internal(set) var candidate: String?
        var committedHead: Head?
    }
    package struct Review: Codable, Equatable, Sendable {
        package let header: Header
        package let items: [Item]
        package init(header: Header, items: [Item]) { self.header = header; self.items = items }
    }
}
