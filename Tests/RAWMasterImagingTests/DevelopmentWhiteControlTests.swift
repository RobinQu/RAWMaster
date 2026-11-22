import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentWhiteControlTests: XCTestCase {
    private func render(_ image: CIImage) -> [SIMD4<Float>] {
        var pixels = [SIMD4<Float>](repeating: .zero, count: Int(image.extent.width * image.extent.height))
        DevelopmentColorEngineV3.context.render(image, toBitmap: &pixels, rowBytes: Int(image.extent.width) * 16,
            bounds: image.extent, format: .RGBAf, colorSpace: DevelopmentColorEngineV3.linearSRGB)
        return pixels
    }

    func testWhiteChangesHighlightsPreservesShadowsAndAlpha() throws {
        let source: [SIMD4<Float>] = [.init(0.1, 0.1, 0.1, 1), .init(0.7, 0.7, 0.7, 0.5), .init(1, 1, 1, 0)]
        let input = CIImage(bitmapData: source.withUnsafeBytes { Data($0) }, bytesPerRow: source.count * 16,
            size: .init(width: source.count, height: 1), format: .RGBAf, colorSpace: DevelopmentColorEngineV3.linearSRGB)
        var p = DevelopmentAdjustmentsV3()
        p.light = .init(enabled: true, whites: 0.8)
        let adjusted = render(try DevelopmentColorEngineV3.applyPointwise(p, to: input))
        p.light.whites = 0
        let baseline = render(try DevelopmentColorEngineV3.applyPointwise(p, to: input))
        XCTAssertEqual(adjusted[0].x, baseline[0].x, accuracy: 0.00001)
        XCTAssertGreaterThan(adjusted[1].x, baseline[1].x * 1.1)
        XCTAssertEqual(adjusted[1].w, 0.5)
        XCTAssertEqual(adjusted[2], source[2], "Fully transparent source components pass through unchanged")
        p.light.whites = 0.8
        XCTAssertTrue(DevelopmentColorEngineV3.pointwiseActive(p))
        p.light.enabled = false
        XCTAssertFalse(DevelopmentColorEngineV3.pointwiseActive(p))
    }

    func testWhiteUsesNativeBindingFourthLightComponent() throws {
        var recipe = try DevelopmentRecipe().promotingToV3()
        recipe.adjustmentsV3!.light = .init(enabled: true, whites: 0.4)
        let binding = try XCTUnwrap(PreviewNativePointwiseCertificateV2.binding(recipe, size: .init(width: 64, height: 48)))
        XCTAssertEqual(binding.floatBits[3], Float(0.4).bitPattern)
        XCTAssertTrue(binding.pointwiseActive)
    }
}
