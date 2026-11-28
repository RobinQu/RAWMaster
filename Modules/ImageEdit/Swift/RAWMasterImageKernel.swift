import CImageEditABI
import Foundation
#if os(macOS)
import Metal
#endif

public enum RAWMasterImageKernel {
    public enum Failure: Error {
        case unavailable, invalidParameters, invalidShader, renderFailed, staleFrame, surfaceBudget, unsupportedScene
    }
    public enum Kernel: UInt32 { case photoFilter = 1, exposure, mask, maskAnalytic, colorGrainLattice }
    public enum FilterFamily: UInt32 { case classicColor = 0, classicMonochrome, spektrafilm }
    public enum Backend: UInt32, Sendable { case cpu, gpu }

    public struct CoveragePlane: Sendable {
        public let id: String
        public let values: [Float]

        public init(id: String, values: [Float]) {
            self.id = id
            self.values = values
        }
    }

    public struct FilterBinding: Sendable {
        public let lowerPercent, upperPercent: Int
        public let weight, amount: Float
        public let hdrMode: UInt32
        public let repairRawAlpha: Bool
    }

    private final class Runtime: @unchecked Sendable {
        let handle: OpaquePointer

        init() throws {
            let url: URL?
            if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
                url = Bundle.main.privateFrameworksURL?.appendingPathComponent("librawmaster_image.dylib")
            } else {
                url = Bundle.module.url(forResource: "rawmaster-image", withExtension: "runtime")
            }
            guard let url, let handle = url.path.withCString({ rm_image_host_open($0) }) else {
                throw Failure.unavailable
            }
            self.handle = handle
        }

        deinit { rm_image_host_close(handle) }
    }

    private static let runtime = Result { try Runtime() }

    public static func source(_ kernel: Kernel) throws -> String {
        let runtime = try runtime.get()
        var length = 0
        guard let bytes = rm_image_host_kernel(runtime.handle, kernel.rawValue, &length), length > 0,
              let text = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            throw Failure.invalidShader
        }
        return text
    }

    public static func exposureGain(ev: Double) throws -> Float {
        let gain = Float(rm_image_host_exposure(try runtime.get().handle, ev))
        guard gain.isFinite && gain > 0 else { throw Failure.invalidParameters }
        return gain
    }

    public static func bindFilter(_ family: FilterFamily, amount: Double, repairRawAlpha: Bool = false) throws -> FilterBinding {
        var result = RMImageFilterBinding()
        let status = rm_image_host_filter(try runtime.get().handle, family.rawValue, amount,
                                          repairRawAlpha ? 1 : 0, &result)
        guard status == 0 else { throw Failure.invalidParameters }
        return FilterBinding(lowerPercent: Int(result.low_percent), upperPercent: Int(result.high_percent),
                             weight: result.weight, amount: result.normalized_amount, hdrMode: result.hdr_mode,
                             repairRawAlpha: result.repair_raw_alpha != 0)
    }

    /// Owns one compiled graph and its immutable resources for batch or bitmap-bound clients.
    /// Rendering accepts tightly packed, top-down extended-linear-sRGB F32 pixels.
    public final class RasterPlan: @unchecked Sendable {
        private let runtime: Runtime
        fileprivate let plan: OpaquePointer
        fileprivate let lock = NSLock()

        public init(recipe: Data, resources: URL? = nil, backend: Backend) throws {
            let runtime = try RAWMasterImageKernel.runtime.get()
            let path = Array((resources?.path ?? "").utf8)
            var plan: OpaquePointer?
            let status = recipe.withUnsafeBytes { bytes in
                path.withUnsafeBufferPointer { path in
                    rm_image_host_plan_open(runtime.handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                                            bytes.count, path.baseAddress, path.count, backend.rawValue, &plan)
                }
            }
            guard status == 0, let plan else { throw status == 2 ? Failure.unavailable : Failure.invalidParameters }
            self.runtime = runtime
            self.plan = plan
        }

        deinit { rm_image_host_plan_close(runtime.handle, plan) }

        public func render(width: UInt32, height: UInt32, rgba: [Float], coverage: [Float] = []) throws -> [Float] {
            let pixels = UInt64(width) * UInt64(height)
            guard pixels > 0, pixels <= UInt64(Int.max / 4), Int(pixels) * 4 == rgba.count,
                  coverage.isEmpty || coverage.count == Int(pixels) else { throw Failure.invalidParameters }
            var destination = [Float](repeating: 0, count: rgba.count)
            let status = lock.withLock {
                rgba.withUnsafeBufferPointer { source in
                    coverage.withUnsafeBufferPointer { mask in
                        destination.withUnsafeMutableBufferPointer { output in
                            rm_image_host_plan_render(runtime.handle, plan, width, height, source.baseAddress,
                                source.count, mask.baseAddress, mask.count, output.baseAddress, output.count)
                        }
                    }
                }
            }
            guard status == 0 else { throw status == 1 ? Failure.invalidParameters : Failure.renderFailed }
            return destination
        }

        public func render(width: UInt32, height: UInt32, rgba: [Float],
                           coveragePlanes: [CoveragePlane]) throws -> [Float] {
            let pixels = UInt64(width) * UInt64(height)
            guard pixels > 0, pixels <= UInt64(Int.max / 4), Int(pixels) * 4 == rgba.count,
                  coveragePlanes.count <= 32, coveragePlanes.allSatisfy({ plane in
                      plane.values.count == Int(pixels) && (1...64).contains(plane.id.utf8.count)
                  }) else { throw Failure.invalidParameters }
            var destination = [Float](repeating: 0, count: rgba.count)
            var descriptors: [RMImageCoverageV2] = []
            descriptors.reserveCapacity(coveragePlanes.count)

            // Every borrowed string and plane stays in scope for the synchronous render at the leaf.
            func renderBoundPlanes(_ index: Int) -> Int32 {
                guard index < coveragePlanes.count else {
                    return descriptors.withUnsafeBufferPointer { named in
                        rgba.withUnsafeBufferPointer { source in
                            destination.withUnsafeMutableBufferPointer { output in
                                rm_image_host_plan_render_v2(runtime.handle, plan, width, height, source.baseAddress,
                                    source.count, named.baseAddress, named.count, output.baseAddress, output.count)
                            }
                        }
                    }
                }
                let plane = coveragePlanes[index]
                var name = plane.id
                return name.withUTF8 { id in
                    plane.values.withUnsafeBufferPointer { values in
                        descriptors.append(RMImageCoverageV2(id: id.baseAddress, id_bytes: id.count,
                            values: values.baseAddress, count: values.count))
                        defer { descriptors.removeLast() }
                        return renderBoundPlanes(index + 1)
                    }
                }
            }

            let status = lock.withLock { renderBoundPlanes(0) }
            switch status {
            case 0: return destination
            case 1: throw Failure.invalidParameters
            case 2: throw Failure.unavailable
            default: throw Failure.renderFailed
            }
        }
    }

    #if os(macOS)
    public struct MetalCoveragePlane {
        public let id: String
        public let texture: any MTLTexture

        public init(id: String, texture: any MTLTexture) {
            self.id = id
            self.texture = texture
        }
    }

    private final class FrameAuthorization {
        let isCurrent: (UInt64) -> Bool
        init(_ isCurrent: @escaping (UInt64) -> Bool) { self.isCurrent = isCurrent }
    }

    private static func withFrameAuthorization<T>(_ isCurrent: @escaping (UInt64) -> Bool,
        _ body: (RMImageMetalIsCurrentV1, UnsafeMutableRawPointer) throws -> T) rethrows -> T {
        let authorization = FrameAuthorization(isCurrent)
        let current: RMImageMetalIsCurrentV1 = { context, revision in
            guard let context else { return 0 }
            return Unmanaged<FrameAuthorization>.fromOpaque(context).takeUnretainedValue().isCurrent(revision) ? 1 : 0
        }
        return try withExtendedLifetime(authorization) {
            try body(current, Unmanaged.passUnretained(authorization).toOpaque())
        }
    }

    /// A compiled GPU graph for joined, exclusive Metal surfaces on this device.
    public final class MetalProgram {
        private let runtime: Runtime
        private let program: OpaquePointer

        public init(recipe: RasterPlan, device: any MTLDevice) throws {
            let runtime = try RAWMasterImageKernel.runtime.get()
            let nativeDevice = Unmanaged.passUnretained(device as AnyObject).toOpaque()
            var result: OpaquePointer?
            let status = withExtendedLifetime(device) {
                recipe.lock.withLock {
                    rm_image_host_metal_program_open(runtime.handle, recipe.plan, nativeDevice, &result)
                }
            }
            guard status == 0, let result else { throw Failure.unavailable }
            self.runtime = runtime
            self.program = result
        }

        /// The caller keeps these surfaces exclusive through the join, then checks its presentation revision.
        public func render(_ parameters: RasterPlan, input: any MTLTexture, coverage: (any MTLTexture)? = nil,
                           output: any MTLTexture, revision: UInt64, isCurrent: @escaping (UInt64) -> Bool) throws {
            guard let width = UInt32(exactly: input.width), let height = UInt32(exactly: input.height) else {
                throw Failure.invalidParameters
            }
            try withExtendedLifetime((input, coverage, output)) {
                var storage = RMImageMetalSurfacesV1()
                storage.struct_size = UInt32(MemoryLayout<RMImageMetalSurfacesV1>.size)
                storage.width = width
                storage.height = height
                storage.input_rgba = Unmanaged.passUnretained(input as AnyObject).toOpaque()
                storage.coverage_r32 = coverage.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() }
                storage.output_rgba = Unmanaged.passUnretained(output as AnyObject).toOpaque()
                try submit(parameters, revision: revision, isCurrent: isCurrent) { frame in
                    rm_image_host_metal_frame_bind(runtime.handle, program, parameters.plan, &storage, frame)
                }
            }
        }

        public func render(_ parameters: RasterPlan, input: any MTLTexture, coveragePlanes: [MetalCoveragePlane],
                           output: any MTLTexture, revision: UInt64, isCurrent: @escaping (UInt64) -> Bool) throws {
            guard let width = UInt32(exactly: input.width), let height = UInt32(exactly: input.height),
                  coveragePlanes.count <= 32, coveragePlanes.allSatisfy({ (1...64).contains($0.id.utf8.count) }) else {
                throw Failure.invalidParameters
            }
            var descriptors: [RMImageMetalCoverageV2] = []
            descriptors.reserveCapacity(coveragePlanes.count)

            func renderBoundPlanes(_ index: Int) throws {
                guard index < coveragePlanes.count else {
                    try descriptors.withUnsafeBufferPointer { named in
                        var storage = RMImageMetalSurfacesV2()
                        storage.struct_size = UInt32(MemoryLayout<RMImageMetalSurfacesV2>.size)
                        storage.width = width
                        storage.height = height
                        storage.input_rgba = Unmanaged.passUnretained(input as AnyObject).toOpaque()
                        storage.output_rgba = Unmanaged.passUnretained(output as AnyObject).toOpaque()
                        storage.coverage = named.baseAddress
                        storage.coverage_count = named.count
                        try submit(parameters, revision: revision, isCurrent: isCurrent) { frame in
                            rm_image_host_metal_frame_bind_v2(runtime.handle, program, parameters.plan, &storage, frame)
                        }
                    }
                    return
                }
                let plane = coveragePlanes[index]
                var name = plane.id
                try name.withUTF8 { id in
                    descriptors.append(RMImageMetalCoverageV2(id: id.baseAddress, id_bytes: id.count,
                        texture: Unmanaged.passUnretained(plane.texture as AnyObject).toOpaque()))
                    defer { descriptors.removeLast() }
                    try renderBoundPlanes(index + 1)
                }
            }

            try withExtendedLifetime((input, coveragePlanes, output)) { try renderBoundPlanes(0) }
        }

        private func submit(_ parameters: RasterPlan, revision: UInt64, isCurrent: @escaping (UInt64) -> Bool,
                            bind: (UnsafeMutablePointer<OpaquePointer?>) -> Int32) throws {
            let status = try RAWMasterImageKernel.withFrameAuthorization(isCurrent) { current, context in
                try parameters.lock.withLock {
                    var frame: OpaquePointer?
                    let bound = bind(&frame)
                    guard bound == 0, let frame else { throw bound == 2 ? Failure.unavailable : Failure.invalidParameters }
                    defer { rm_image_host_metal_frame_close(runtime.handle, frame) }
                    return rm_image_host_metal_frame_render(runtime.handle, frame, parameters.plan, revision, current, context)
                }
            }
            if status == 5 { throw Failure.staleFrame }
            guard status == 0 else { throw Failure.renderFailed }
        }

        deinit { rm_image_host_metal_program_close(runtime.handle, program) }
    }

    /// An immutable device program for an eligible opaque native graph and its physical half.
    public final class NativeHalfProgram {
        public static let maximumScratchBytes = Int(RM_IMAGE_METAL_HALF_MAX_SCRATCH_BYTES)
        private let runtime: Runtime
        private let program: OpaquePointer

        /// A region program gives an explicitly partial receipt when patchOnly is true.
        public struct MaskRegion {
            public let x, y, width, height: UInt32
            public let patchOnly: Bool

            public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32, patchOnly: Bool) {
                self.x = x
                self.y = y
                self.width = width
                self.height = height
                self.patchOnly = patchOnly
            }
        }

        public convenience init(recipe: RasterPlan, device: any MTLDevice, frozenMask: Bool = false) throws {
            try self.init(recipe: recipe, device: device, frozenMask: frozenMask, compactRegion: false)
        }

        public init(recipe: RasterPlan, device: any MTLDevice, frozenMask: Bool, compactRegion: Bool) throws {
            guard !compactRegion || frozenMask else { throw Failure.invalidParameters }
            let runtime = try RAWMasterImageKernel.runtime.get()
            var handle: OpaquePointer?
            let status = withExtendedLifetime(device) {
                recipe.lock.withLock {
                    let pointer = Unmanaged.passUnretained(device as AnyObject).toOpaque()
                    if compactRegion {
                        return rm_image_host_metal_mask_region_program_open(runtime.handle, recipe.plan, pointer, &handle)
                    }
                    if frozenMask {
                        return rm_image_host_metal_mask_half_program_open(runtime.handle, recipe.plan, pointer, &handle)
                    }
                    return rm_image_host_metal_half_program_open(runtime.handle, recipe.plan, pointer, &handle)
                }
            }
            try Self.check(status)
            guard let handle else { throw Failure.renderFailed }
            self.runtime = runtime
            self.program = handle
        }

        /// Holds both texture references through the GPU join. The caller owns the completed source
        /// producer and exclusive destination leases, and must recheck revision before presentation.
        public func render(_ parameters: RasterPlan, input: any MTLTexture, output: any MTLTexture,
                           revision: UInt64, isCurrent: @escaping (UInt64) -> Bool) throws {
            try render(parameters, input: input, coverage: nil, output: output, revision: revision, isCurrent: isCurrent)
        }

        /// The initialized R32F coverage uses absolute source coordinates with its bottom row first.
        public func render(_ parameters: RasterPlan, input: any MTLTexture, coverage: (id: String, texture: any MTLTexture)?,
                           output: any MTLTexture, revision: UInt64, isCurrent: @escaping (UInt64) -> Bool) throws {
            try render(parameters, input: input, coverage: coverage, region: nil, output: output, revision: revision, isCurrent: isCurrent)
        }

        /// A compact patch validates its native rectangle and leaves the initialized exterior untouched.
        public func render(_ parameters: RasterPlan, input: any MTLTexture, coverage: (id: String, texture: any MTLTexture)?,
                           region: MaskRegion?, output: any MTLTexture, revision: UInt64, isCurrent: @escaping (UInt64) -> Bool) throws {
            if region != nil, coverage == nil { throw Failure.invalidParameters }
            let status = withExtendedLifetime((input, output, coverage)) {
                RAWMasterImageKernel.withFrameAuthorization(isCurrent) { current, context in
                    parameters.lock.withLock {
                        let source = Unmanaged.passUnretained(input as AnyObject).toOpaque()
                        let target = Unmanaged.passUnretained(output as AnyObject).toOpaque()
                        if let coverage {
                            let texture = Unmanaged.passUnretained(coverage.texture as AnyObject).toOpaque()
                            return Array(coverage.id.utf8).withUnsafeBufferPointer { name in
                                if let region {
                                    var bounds = RMImageMetalMaskRegionV1(x: region.x, y: region.y,
                                        width: region.width, height: region.height, patch_only: region.patchOnly ? 1 : 0)
                                    return rm_image_host_metal_mask_region_render(runtime.handle, program, parameters.plan, source,
                                        name.baseAddress, name.count, texture, target, &bounds, revision, current, context)
                                }
                                return rm_image_host_metal_mask_half_render(runtime.handle, program, parameters.plan, source,
                                    name.baseAddress, name.count, texture, target, revision, current, context)
                            }
                        }
                        return rm_image_host_metal_half_render(runtime.handle, program, parameters.plan,
                            source, target, revision, current, context)
                    }
                }
            }
            try Self.check(status)
        }

        private static func check(_ status: Int32) throws {
            switch status {
            case 0: break
            case 1: throw Failure.invalidParameters
            case 2: throw Failure.unavailable
            case 5: throw Failure.staleFrame
            case 6: throw Failure.surfaceBudget
            default: throw Failure.renderFailed
            }
        }

        deinit { rm_image_host_metal_half_program_close(runtime.handle, program) }
    }
    /// Executes the native 037/038 scene-linear AP1 graph. The image surfaces are
    /// borrowed RGBA32Float Metal textures; output must be an exclusive scratch texture.
    public enum SceneView {
        case final
        case node(String)
        case bypass

        fileprivate var selector: [String: Any] {
            switch self {
            case .final: ["target": "final"]
            case .bypass: ["target": "bypass"]
            case .node(let id): ["target": "node", "id": id]
            }
        }
    }

    /// Strict wgpu scene execution over a completed native Metal input.
    public final class AP1MetalProgram {
        public struct Receipt: Sendable {
            public let nodes, dispatches, submissions, hostWaits, pipelineBuilds: Int
            public let peakBytes, budgetBytes: Int
            public let frameCopyBytes, validationBytes, submitWaitNanoseconds: UInt64
            public let cpuMilliseconds: Double
        }

        private let runtime: Runtime
        private let program: OpaquePointer
        private let lock = NSLock()

        public init(device: any MTLDevice) throws {
            let runtime = try RAWMasterImageKernel.runtime.get()
            var handle: OpaquePointer?
            let status = withExtendedLifetime(device) {
                rm_image_host_scene_ap1_metal_open(runtime.handle,
                    Unmanaged.passUnretained(device as AnyObject).toOpaque(), &handle)
            }
            guard status == 0, let handle else {
                throw status == 2 ? Failure.unavailable : Failure.renderFailed
            }
            self.runtime = runtime
            program = handle
        }

        public func render(graph: Data, input: any MTLTexture, view: SceneView,
                           origin: SIMD2<Int>, geometry: SIMD2<Int>, surfaceBudget: Int,
                           revision: UInt64 = 0, isCurrent: @escaping (UInt64) -> Bool = { _ in true })
            throws -> (texture: any MTLTexture, receipt: Receipt) {
            var payload = view.selector
            payload["origin"] = [origin.x, origin.y]
            payload["geometry"] = [geometry.x, geometry.y]
            payload["surfaceBudget"] = surfaceBudget
            let viewData = try JSONSerialization.data(withJSONObject: payload)
            var output: UnsafeMutableRawPointer?
            var raw = RMSceneAP1MetalReceiptV1()
            let status = lock.withLock {
                withExtendedLifetime(input) {
                    RAWMasterImageKernel.withFrameAuthorization(isCurrent) { current, context in
                        graph.withUnsafeBytes { document in
                            viewData.withUnsafeBytes { selection in
                                rm_image_host_scene_ap1_metal_render(runtime.handle, program,
                                    document.bindMemory(to: UInt8.self).baseAddress, document.count,
                                    Unmanaged.passUnretained(input as AnyObject).toOpaque(), &output,
                                    selection.bindMemory(to: UInt8.self).baseAddress, selection.count,
                                    &raw, revision, current, context)
                            }
                        }
                    }
                }
            }
            switch status {
            case 0: break
            case 1: throw Failure.invalidParameters
            case 2: throw Failure.unavailable
            case 5: throw Failure.staleFrame
            case 6: throw Failure.surfaceBudget
            case 7: throw Failure.unsupportedScene
            default: throw Failure.renderFailed
            }
            guard let output,
                  let texture = Unmanaged<AnyObject>.fromOpaque(output).takeRetainedValue() as? any MTLTexture else {
                throw Failure.renderFailed
            }
            let receipt = Receipt(nodes: Int(raw.nodes), dispatches: Int(raw.dispatches),
                submissions: Int(raw.submissions), hostWaits: Int(raw.host_waits), pipelineBuilds: Int(raw.pipeline_builds),
                peakBytes: Int(raw.peak_bytes), budgetBytes: Int(raw.budget_bytes), frameCopyBytes: raw.frame_copy_bytes,
                validationBytes: raw.validation_bytes, submitWaitNanoseconds: raw.submit_wait_ns, cpuMilliseconds: raw.cpu_ms)
            return (texture, receipt)
        }

        deinit { rm_image_host_scene_ap1_metal_close(runtime.handle, program) }
    }

    public final class SceneProgram {
        public struct SceneReceipt: Sendable, Equatable {
            public let tiles, nodes, dispatches, coverageHits, nodeHits: Int
            public let peakBytes, budgetBytes: Int
            public let cpuMilliseconds: Double
        }

        private let runtime: Runtime
        private let program: OpaquePointer

        public init(graph: Data, device: any MTLDevice) throws {
            let runtime = try RAWMasterImageKernel.runtime.get()
            var handle: OpaquePointer?
            let status = graph.withUnsafeBytes { bytes in
                withExtendedLifetime(device) {
                    rm_image_host_scene_open(runtime.handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, Unmanaged.passUnretained(device as AnyObject).toOpaque(), &handle)
                }
            }
            guard status == 0, let handle else {
                throw status == 2 ? Failure.unavailable : Failure.invalidParameters
            }
            self.runtime = runtime
            self.program = handle
        }

        private init(runtime: Runtime, program: OpaquePointer) {
            self.runtime = runtime
            self.program = program
        }

        /// Returns nil only when the loaded runtime predates the frozen delivery constructor.
        /// The count measures calls to Metal's library API, including an unsuccessful call.
        public static func openFrozenDelivery(graph: Data, device: any MTLDevice,
                                              libraryAPICalls: inout UInt32) throws -> SceneProgram? {
            libraryAPICalls = 0
            let runtime = try RAWMasterImageKernel.runtime.get()
            var handle: OpaquePointer?
            let status = graph.withUnsafeBytes { bytes in
                withExtendedLifetime(device) {
                    rm_image_host_scene_open_frozen_delivery(runtime.handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, Unmanaged.passUnretained(device as AnyObject).toOpaque(), &libraryAPICalls, &handle)
                }
            }
            if status == Int32(RM_IMAGE_HOST_SCENE_FROZEN_OPEN_MISSING) { return nil }
            guard status == 0, let handle else {
                throw status == 2 ? Failure.unavailable : Failure.invalidParameters
            }
            return SceneProgram(runtime: runtime, program: handle)
        }

        public func update(graph: Data) throws {
            let status = graph.withUnsafeBytes { bytes in
                rm_image_host_scene_update(runtime.handle, program,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            switch status {
            case 0: break
            case 1: throw Failure.invalidParameters
            case 2: throw Failure.unavailable
            default: throw Failure.renderFailed
            }
        }

        public func receipt() -> SceneReceipt? {
            var raw = RMSceneReceiptV1()
            guard rm_image_host_scene_receipt(runtime.handle, program, &raw) == 0 else { return nil }
            return .init(tiles: Int(raw.tiles), nodes: Int(raw.nodes), dispatches: Int(raw.dispatches),
                coverageHits: Int(raw.coverage_hits), nodeHits: Int(raw.node_hits),
                peakBytes: Int(raw.peak_bytes), budgetBytes: Int(raw.budget_bytes),
                cpuMilliseconds: raw.cpu_ms)
        }

        public func render(input: any MTLTexture, output: any MTLTexture, view: SceneView = .final, groupPath: [UUID] = [],
                           origin: SIMD2<Int> = .zero, geometry: SIMD2<Int>? = nil,
                           surfaceBudget: Int? = nil,
                           tileEdge: Int? = nil, sourceRevision: UInt64 = 0,
                           coverages: [UUID: any MTLTexture] = [:],
                           revision: UInt64 = 0, isCurrent: @escaping (UInt64) -> Bool = { _ in true }) throws {
            _ = try renderResult(input: input, output: output, view: view, groupPath: groupPath,
                origin: origin, geometry: geometry, surfaceBudget: surfaceBudget, tileEdge: tileEdge,
                sourceRevision: sourceRevision, coverages: coverages, revision: revision, isCurrent: isCurrent)
        }

        /// Returns the completed graph surface. A single-tile graph does not need a separate destination texture.
        public func renderSurface(input: any MTLTexture, view: SceneView = .final, groupPath: [UUID] = [],
                                  origin: SIMD2<Int> = .zero, geometry: SIMD2<Int>? = nil,
                                  surfaceBudget: Int? = nil, tileEdge: Int? = nil, sourceRevision: UInt64 = 0,
                                  coverages: [UUID: any MTLTexture] = [:],
                                  revision: UInt64 = 0, isCurrent: @escaping (UInt64) -> Bool = { _ in true }) throws -> any MTLTexture {
            try renderResult(input: input, output: nil, view: view, groupPath: groupPath, origin: origin,
                geometry: geometry, surfaceBudget: surfaceBudget, tileEdge: tileEdge, sourceRevision: sourceRevision,
                coverages: coverages, revision: revision, isCurrent: isCurrent)
        }

        private func renderResult(input: any MTLTexture, output: (any MTLTexture)?, view: SceneView, groupPath: [UUID],
                                  origin: SIMD2<Int>, geometry: SIMD2<Int>?, surfaceBudget: Int?, tileEdge: Int?,
                                  sourceRevision: UInt64, coverages: [UUID: any MTLTexture], revision: UInt64,
                                  isCurrent: @escaping (UInt64) -> Bool) throws -> any MTLTexture {
            var payload = view.selector
            payload["origin"] = [origin.x, origin.y]
            if !groupPath.isEmpty { payload["groupPath"] = groupPath.map(\.uuidString) }
            if let geometry { payload["geometry"] = [geometry.x, geometry.y] }
            if let surfaceBudget { payload["surfaceBudget"] = surfaceBudget }
            if let tileEdge { payload["tileEdge"] = tileEdge }
            if sourceRevision != 0 { payload["sourceRevision"] = sourceRevision }
            let viewData = try JSONSerialization.data(withJSONObject: payload)
            let entries = Array(coverages)
            var retained: UnsafeMutableRawPointer?
            let status = withExtendedLifetime((input, output, entries.map(\.1))) {
                RAWMasterImageKernel.withFrameAuthorization(isCurrent) { current, context in
                    viewData.withUnsafeBytes { bytes in
                        func render(_ ids: UnsafePointer<UnsafePointer<CChar>?>?,
                                    _ textures: UnsafePointer<UnsafeMutableRawPointer?>?) -> Int32 {
                            let source = Unmanaged.passUnretained(input as AnyObject).toOpaque()
                            let view = bytes.bindMemory(to: UInt8.self).baseAddress
                            guard let output else {
                                return rm_image_host_scene_render_surface(runtime.handle, program, source, &retained,
                                    view, bytes.count, ids, textures, entries.count, revision, current, context)
                            }
                            let target = Unmanaged.passUnretained(output as AnyObject).toOpaque()
                            if entries.isEmpty {
                                return rm_image_host_scene_render(runtime.handle, program, source, target,
                                    view, bytes.count, revision, current, context)
                            }
                            return rm_image_host_scene_render_coverages(runtime.handle, program, source, target,
                                view, bytes.count, ids, textures, entries.count, revision, current, context)
                        }
                        if entries.isEmpty { return render(nil, nil) }
                        var names: [CChar] = [], offsets: [Int] = []
                        for entry in entries {
                            offsets.append(names.count)
                            names.append(contentsOf: entry.0.uuidString.utf8.map { CChar(bitPattern: $0) })
                            names.append(0)
                        }
                        var textures: [UnsafeMutableRawPointer?] = entries.map {
                            Unmanaged.passUnretained($0.1 as AnyObject).toOpaque()
                        }
                        return names.withUnsafeMutableBufferPointer { buffer in
                            var ids: [UnsafePointer<CChar>?] = offsets.map { UnsafePointer(buffer.baseAddress! + $0) }
                            return ids.withUnsafeMutableBufferPointer { idPointers in
                                textures.withUnsafeMutableBufferPointer { texturePointers in
                                    render(idPointers.baseAddress, texturePointers.baseAddress)
                                }
                            }
                        }
                    }
                }
            }
            switch status {
            case 0:
                if let output { return output }
                guard let retained, let result = Unmanaged<AnyObject>.fromOpaque(retained).takeRetainedValue() as? any MTLTexture else {
                    throw Failure.renderFailed
                }
                return result
            case 1: throw Failure.invalidParameters
            case 2: throw Failure.unavailable
            case 5: throw Failure.staleFrame
            case 6: throw Failure.surfaceBudget
            default: throw Failure.renderFailed
            }
        }

        deinit { rm_image_host_scene_close(runtime.handle, program) }
    }
    #endif
}
