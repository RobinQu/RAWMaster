import CoreImage
import Foundation
import RAWMasterImage

enum DevelopmentPortableExposure {
    private static let kernel = Result {
        guard let kernel = try CIKernel.kernels(withMetalString: RAWMasterImageKernel.source(.exposure))
            .first(where: { $0.name == "rmImageLinearExposure" }) as? CIColorKernel else {
            throw DevelopmentError.unsupportedEngine
        }
        return kernel
    }

    static func apply(_ ev: Double, to image: CIImage) throws -> CIImage {
        let gain = try RAWMasterImageKernel.exposureGain(ev: ev)
        guard let result = try kernel.get().apply(extent: image.extent, arguments: [image, NSNumber(value: gain)]) else {
            throw DevelopmentError.unreadable
        }
        return result
    }
}
