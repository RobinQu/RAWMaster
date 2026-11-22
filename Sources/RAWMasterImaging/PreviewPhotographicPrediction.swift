import CoreImage
import Metal

extension PreviewInteractiveProxyPool {
    /// Keeps one native, source-bound FP32 network result. The final two Amounts still
    /// use the normal presentation cache. A competing pane can reclaim this optional input.
    func pinPhotographicPrediction(descriptor: PreviewInteractiveInputDescriptor, layout: PreviewInteractiveLayout,
                                   original: CIImage, context: CIContext, device: MTLDevice,
                                   scope: PreviewPresentationScope, check: () throws -> Void) throws -> Pin? {
        guard let pool = photographicPredictions else { return nil }
        var key = descriptor
        key.nativeContract = DevelopmentPhotoDenoise.previewPredictionContract
        if let pin = try pool.lookup(key) { return pin }
        let build = try pool.beginBuild(key)
        defer { pool.endBuild(build) }
        pool.evictUnpinnedBeforeFill()
        scope.ledger.registerOptionalNeuralInputs(pool)
        let ticket: PreviewPresentationReservation
        do { ticket = try scope.reserveSharedSurface(bytes: layout.bytes) }
        catch PreviewPresentationError.displayCapacity { return nil }
        let storage = try PreviewInteractiveProxyStorage(layout: layout, ticket: ticket, device: device)
        try pool.attachBuildingStorage(storage, id: build)
        let native = try DevelopmentPhotoDenoise.prediction(from: original)
        let canvas = PreviewInteractiveProxyV3.canvas(native.samplingLinear(), width: layout.width, height: layout.height)
        try storage.fill(PreviewInteractiveProxyV3.transportAlpha(canvas), context: context, check: check)
        try check()
        return try pool.publish(key, storage, buildID: build)
    }
}
