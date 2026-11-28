import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// Swift owner for the legacy and wgpu Rust scene executors.
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
    private var ap1: RAWMasterImageKernel.AP1MetalProgram?
    private var ap1Document: (scope: Scope, data: Data)?

    init(device: any MTLDevice, frozenDelivery: Bool = false,
         openFrozen: @escaping FrozenOpen = RAWMasterImageKernel.SceneProgram.openFrozenDelivery) {
        self.device = device
        self.openFrozen = openFrozen
        reuse = frozenDelivery ? .frozenDelivery : .editable
    }

    enum Mode { case auto, rust, swift, wgpu }

    static var mode: Mode {
        switch ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() {
        case "rust": return .rust
        case "swift", "off", "0": return .swift
        case "wgpu": return .wgpu
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
        do {
            let texture = try SceneDeliveryTrace.measure(.dagDispatch) {
                try program.renderSurface(input: input, view: Self.selector(view), groupPath: view.groupPath,
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

    func renderWGSL(input: any MTLTexture, scope: DevelopmentSceneGraphV1.Scope, view: DevelopmentSceneGraphV1.View,
                    origin: SIMD2<Int>, geometry: SIMD2<Int>, surfaceBudget: Int)
      throws -> (texture: any MTLTexture, receipt: RAWMasterImageKernel.AP1MetalProgram.Receipt) {
        let document: Data
        if let previous = ap1Document, previous.scope == scope {
            document = previous.data
        } else {
            document = try Self.encode(scope)
            ap1Document = (scope, document)
        }
        let program = try ap1 ?? SceneDeliveryTrace.measure(.dagWGPUOpen) {
            try RAWMasterImageKernel.AP1MetalProgram(device: device)
        }
        ap1 = program
        do {
            let result = try SceneDeliveryTrace.measure(.dagWGPURender) {
                try program.render(graph: document, input: input, view: Self.selector(view), origin: origin,
                    geometry: geometry, surfaceBudget: surfaceBudget, isCurrent: { _ in !Task.isCancelled })
            }
            SceneDeliveryTrace.recordWGPU(result.receipt)
            SceneDeliveryTrace.sampleMemory(device: device)
            return result
        } catch RAWMasterImageKernel.Failure.surfaceBudget {
            throw DevelopmentSceneGraphRendererV1.Failure.surfaceBudget
        } catch RAWMasterImageKernel.Failure.staleFrame {
            try Task.checkCancellation()
            throw RAWMasterImageKernel.Failure.staleFrame
        }
    }

    private static func selector(_ view: DevelopmentSceneGraphV1.View) -> RAWMasterImageKernel.SceneView {
        switch view.target {
        case .final: .final
        case .bypass: .bypass
        case .node(let id): .node(id.uuidString)
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
