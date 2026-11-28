import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// Thin Swift owner for the Rust scene-linear graph executor. The Swift Metal graph remains the
/// reference implementation; this backend is only selected after the shadow comparison passes.
final class RustSceneGraphRenderer {
    typealias FrozenOpen = (Data, any MTLDevice, inout UInt32) throws -> RAWMasterImageKernel.SceneProgram?
    private typealias Program = RAWMasterImageKernel.SceneProgram
    private typealias Scope = DevelopmentSceneGraphV1.Scope

    private enum Reuse {
        case editable
        case frozenDelivery
        case legacyDelivery
        case frozen(Program, Scope)
    }

    private let device: any MTLDevice
    private let openFrozen: FrozenOpen
    private var reuse: Reuse
    private var programs: [String: Program] = [:]

    init(device: any MTLDevice, frozenDelivery: Bool = false,
         openFrozen: @escaping FrozenOpen = RAWMasterImageKernel.SceneProgram.openFrozenDelivery) {
        self.device = device
        self.openFrozen = openFrozen
        reuse = frozenDelivery ? .frozenDelivery : .editable
    }

    enum Mode { case auto, rust, swift }

    static var mode: Mode {
        switch ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() {
        case "rust": return .rust
        case "swift", "off", "0": return .swift
        default: return .auto
        }
    }

    func render(input: any MTLTexture,
                graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                origin: SIMD2<Int>, geometry: SIMD2<Int>,
                surfaceBudget: Int, tileEdge: Int?, sourceRevision: UInt64,
                coverages: [UUID: any MTLTexture] = [:]) throws
      -> (texture: any MTLTexture, receipt: RAWMasterImageKernel.SceneProgram.SceneReceipt) {
        let program = try preparedProgram(graph.graph)
        let sceneView: RAWMasterImageKernel.SceneView = switch view.target {
        case .final: .final
        case .bypass: .bypass
        case .node(let id): .node(id.uuidString)
        }
        do {
            let texture = try SceneDeliveryTrace.measure(.dagDispatch) {
                try program.renderSurface(input: input, view: sceneView, groupPath: view.groupPath,
                    origin: origin, geometry: geometry, surfaceBudget: surfaceBudget,
                    tileEdge: tileEdge, sourceRevision: sourceRevision, coverages: coverages)
            }
            SceneDeliveryTrace.sampleMemory(device: device)
            guard let receipt = program.receipt() else { throw RAWMasterImageKernel.Failure.renderFailed }
            return (texture, receipt)
        } catch RAWMasterImageKernel.Failure.surfaceBudget {
            throw DevelopmentSceneGraphRendererV1.Failure.surfaceBudget
        }
    }

    private func preparedProgram(_ scope: Scope) throws -> Program {
        switch reuse {
        case .frozen(let program, let frozenScope):
            guard scope == frozenScope else { throw RAWMasterImageKernel.Failure.invalidParameters }
            return program
        case .frozenDelivery:
            let data = try Self.encode(scope)
            return try SceneDeliveryTrace.measure(.dagOpen) {
                var libraryCalls: UInt32 = 0
                defer {
                    if libraryCalls > 0 { SceneDeliveryTrace.recordPreparation(.rustLibraryCalls(Int(libraryCalls))) }
                }
                if let program = try openFrozen(data, device, &libraryCalls) {
                    reuse = .frozen(program, scope)
                    SceneDeliveryTrace.recordPreparation(.programOpened(frozen: true))
                    return program
                }
                reuse = .legacyDelivery
                return try openEditable(data)
            }
        case .legacyDelivery:
            let data = try Self.encode(scope)
            return try SceneDeliveryTrace.measure(.dagOpen) { try openEditable(data) }
        case .editable:
            let data = try Self.encode(scope)
            let key = Self.topology(scope)
            if let cached = programs[key] {
                try SceneDeliveryTrace.measure(.dagUpdate) { try cached.update(graph: data) }
                return cached
            }
            if programs.count >= 8 { programs.removeAll(keepingCapacity: true) }
            let created = try SceneDeliveryTrace.measure(.dagOpen) { try openEditable(data) }
            programs[key] = created
            return created
        }
    }

    private func openEditable(_ data: Data) throws -> Program {
        SceneDeliveryTrace.recordPreparation(.rustOpenWithoutLibraryCount)
        let program = try Program(graph: data, device: device)
        SceneDeliveryTrace.recordPreparation(.programOpened(frozen: false))
        return program
    }

    private static func encode(_ scope: Scope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SceneDeliveryTrace.measure(.dagBridgeEncode) { try encoder.encode(Document(graph: scope)) }
    }

    /// Programs are reusable while node identities and group nesting stay fixed. Node parameter
    /// changes are applied with `update`, and Rust invalidates cache entries by content.
    private static func topology(_ scope: DevelopmentSceneGraphV1.Scope) -> String {
        scope.nodes.map { node in
            switch node.operation {
            case .group(_, let child, _, _):
                return "\(node.id.uuidString){\(topology(child))}"
            default:
                return node.id.uuidString
            }
        }.joined(separator: ",") + ">\(scope.output)"
    }

    private struct Document: Encodable {
        let schemaVersion = 1
        let graph: DevelopmentSceneGraphV1.Scope
    }
}
