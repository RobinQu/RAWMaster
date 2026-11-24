import CoreImage
import ImageIO
import RAWMasterCore
import RAWMasterImage

/// Materializes confirmed, source-bound selections for a portable DAG on the full oriented source grid.
enum DevelopmentPortableFrozenCoverage {
    struct Source {
        let image: CIImage
        fileprivate let binding: DevelopmentLocalEditSourceBinding
        fileprivate let capture: RenderFiles.VerifiedCapture

        private init(image: CIImage, binding: DevelopmentLocalEditSourceBinding, capture: RenderFiles.VerifiedCapture) {
            self.image = image
            self.binding = binding
            self.capture = capture
        }

        static func flashRaw(_ capture: RenderFiles.VerifiedCapture, binding: DevelopmentLocalEditSourceBinding,
                             maximumLongEdge: Int) throws -> Source {
            guard maximumLongEdge > 0, PhotoRenderer.rawExtensions.contains(capture.url.pathExtension.lowercased()) else {
                throw EditingError.invalidRecipe
            }
            return try decode(capture, binding: binding) { url in
                try FlashRawImageFactory.linearImage(capture: url, analysis: (binding, maximumLongEdge))
            }
        }

        static func rendered(_ capture: RenderFiles.VerifiedCapture, binding: DevelopmentLocalEditSourceBinding) throws -> Source {
            guard !PhotoRenderer.rawExtensions.contains(capture.url.pathExtension.lowercased()) else {
                throw EditingError.invalidRecipe
            }
            return try decode(capture, binding: binding) { url in
                guard let file = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
                      let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == binding.exifOrientation,
                      image.extent.size == CGSize(width: binding.orientedWidth, height: binding.orientedHeight) else {
                    throw EditingError.staleSource
                }
                return image
            }
        }

        private static func decode(_ capture: RenderFiles.VerifiedCapture, binding: DevelopmentLocalEditSourceBinding,
                                   load: (URL) throws -> CIImage) throws -> Source {
            try Task.checkCancellation()
            try binding.validate()
            guard capture.contentSHA256 == binding.sourceContentID else { throw EditingError.staleSource }
            let image = try capture.withCurrent(at: capture.url) { try load(capture.url) }
            try Task.checkCancellation()
            return Source(image: image, binding: binding, capture: capture)
        }
    }

    static func planes(for layers: [DevelopmentMaskLayerV3], input: Source, context: CIContext, byteBudget: Int,
                       requireCurrent: () throws -> Void) throws -> [RAWMasterImageKernel.CoveragePlane] {
        let source = input.binding, capture = input.capture, image = input.image
        func check() throws {
            try Task.checkCancellation()
            try requireCurrent()
            try capture.requireCurrent(at: capture.url)
        }
        try check()
        try DevelopmentMaskLayerV3.validateLayers(layers)
        try DevelopmentMaskLayerV3.validateSource(layers, expected: source)
        guard layers.allSatisfy({ $0.kind == .subject && $0.semanticSnapshot != nil }),
              image.extent.origin == .zero, let width = Int(exactly: image.extent.width),
              let height = Int(exactly: image.extent.height), width > 0, height > 0,
              width <= source.orientedWidth, height <= source.orientedHeight else {
            throw EditingError.invalidRecipe
        }
        let scale = Double(max(width, height)) / Double(max(source.orientedWidth, source.orientedHeight))
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width == max(1, Int((Double(source.orientedWidth) * scale).rounded())),
              height == max(1, Int((Double(source.orientedHeight) * scale).rounded())),
              !overflow, UInt32(exactly: count) != nil, byteBudget >= 0,
              layers.count <= byteBudget / MemoryLayout<Float>.stride / count else {
            throw EditingError.invalidRecipe
        }
        var planes: [RAWMasterImageKernel.CoveragePlane] = []
        for layer in layers {
            try check()
            var values = [Float](repeating: layer.enabled ? .nan : 0, count: count)
            if layer.enabled {
                let selection = DevelopmentMaskEngineV3.ScopeSelection(layer)
                try selection.capture(image)
                guard let coverage = selection.coverage, coverage.extent == image.extent else {
                    throw DevelopmentV3Error.invalidGraph
                }
                try values.withUnsafeMutableBytes { bytes in
                    let output = CIRenderDestination(bitmapData: bytes.baseAddress!, width: width, height: height,
                                                     bytesPerRow: width * MemoryLayout<Float>.stride, format: .Rf)
                    output.colorSpace = nil
                    output.alphaMode = .none
                    output.isClamped = false
                    output.isDithered = false
                    output.isFlipped = true
                    let task = try context.startTask(toRender: coverage, from: image.extent, to: output, at: .zero)
                    _ = try task.waitUntilCompleted()
                }
                try check()
                guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw DevelopmentV3Error.invalidGraph
                }
            }
            planes.append(.init(id: layer.id.uuidString.lowercased(), values: values))
        }
        try check()
        return planes
    }
}
