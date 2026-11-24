import CoreImage
import RAWMasterCore
import RAWMasterImage
import XCTest
@testable import RAWMasterImaging

final class PortableImageIntegrationTests: XCTestCase {
    func testExactStrengthAndFilmBindingsFromPackagedCore() throws {
        let native = try RAWMasterImageKernel.bindFilter(.classicMonochrome, amount: 100, repairRawAlpha: true)
        let rounded = try RAWMasterImageKernel.bindFilter(.classicMonochrome, amount: Double(100).nextDown)
        XCTAssertEqual(native.lowerPercent, 100)
        XCTAssertEqual(native.upperPercent, 100)
        XCTAssertEqual(native.weight, 0)
        XCTAssertEqual(native.hdrMode, 2)
        XCTAssertTrue(native.repairRawAlpha)
        XCTAssertEqual(rounded.lowerPercent, 50)
        XCTAssertEqual(rounded.upperPercent, 100)
        XCTAssertEqual(rounded.hdrMode, 1)
        XCTAssertEqual(rounded.amount, 1, "The endpoint rule uses the original Double")
        let first = try RAWMasterImageKernel.bindFilter(.classicColor, amount: 0.5)
        XCTAssertEqual(first.lowerPercent, 0)
        XCTAssertEqual(first.upperPercent, 1)
        XCTAssertEqual(first.weight, 0.5)
        let film = try RAWMasterImageKernel.bindFilter(.spektrafilm, amount: 39)
        XCTAssertEqual(film.lowerPercent, 0)
        XCTAssertEqual(film.upperPercent, 100)
        XCTAssertEqual(film.weight, 0.39)
        XCTAssertThrowsError(try RAWMasterImageKernel.bindFilter(.spektrafilm, amount: .nan))
    }

    func testAppExposureRetainsLinearMathAndSystemFilterTolerance() throws {
        let pixels: [Float] = [-0.03, 0.5, 1.6, 1, 0.20, 0.05, -0.01, 0.5, 0, 0, 0, 0]
        let source = floatImage(pixels)
        for ev in [-4.0, -0.37, 0.37, 1.0, 4.0] {
            let native = try DevelopmentPortableExposure.apply(ev, to: source)
            let expected = source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
            let actualPixels = read(native)
            let reference = read(expected)
            for index in pixels.indices {
                let channel = index % 4
                let analytical = channel == 3 ? pixels[index] : pixels[index] * Float(exp2(ev))
                XCTAssertEqual(actualPixels[index], analytical, accuracy: max(2e-6, abs(analytical) * 2e-6))
                XCTAssertEqual(actualPixels[index], reference[index], accuracy: max(2e-6, abs(analytical) * 2e-6))
                if channel == 3 { XCTAssertEqual(actualPixels[index], pixels[index]) }
            }
        }
    }

    func testPackagedGraphAndAppUseTheSameFilterAssets() throws {
        let path = try XCTUnwrap(DevelopmentPhotoFilterResourceStore.bundledRoot)
        let pixels: [Float] = [-0.03, 0.5, 1.6, 1, 0.20, 0.05, -0.01, 0.5, 0, 0, 0, 0]
        let source = floatImage(pixels)
        for look: DevelopmentPhotoFilterV3 in [.mono, .vivid, .spektraVelvia100] {
            let recipe: [String: Any] = [
                "version": 1, "working": "extended-linear-srgb-premul-f32", "output": "result",
                "nodes": [["id": "s", "op": "source"],
                          ["id": "exp", "op": "exposure", "image": "s", "ev": 0.25],
                          ["id": "result", "op": "photo_filter", "image": "exp", "look": look.rawValue, "amount": 37.5]]
            ]
            let data = try JSONSerialization.data(withJSONObject: recipe)
            let plan = try RAWMasterImageKernel.RasterPlan(recipe: data, resources: path, backend: .cpu)
            let adjusted = try DevelopmentPortableExposure.apply(0.25, to: source)
            let graph = try DevelopmentPhotoFilterEngineV3.apply(
                DevelopmentFilterV3(enabled: true, selection: look, intensity: 37.5), to: adjusted)
            let native = read(graph)
            let portable = try plan.render(width: 3, height: 1, rgba: pixels)
            XCTAssertEqual(native.count, portable.count)
            for i in native.indices { XCTAssertEqual(native[i], portable[i], accuracy: 2e-6, look.rawValue) }
        }
    }

    func testPortableBasicReplaysTheV3PointPass() throws {
        let pixels: [Float] = [-0.03, 0.5, 1.6, 1, 0.20, 0.05, -0.01, 0.5, 0, 0, 0, 0,
                               0.22, 0.08, 0.5, 1, 0.56, 0.33, 0.14, 0.8, 0.0031308, -0.00092, 0, 1]
        let source = floatImage(pixels)
        var light = DevelopmentAdjustmentsV3()
        light.light = .init(enabled: true, brightness: 0.45, contrast: -0.32, blackPoint: -0.09, whites: 0.6)
        var color = DevelopmentAdjustmentsV3()
        color.light.enabled = true // This zero-valued group still runs when color is active.
        color.color = .init(enabled: true, saturation: 0.25, vibrance: -0.30, cast: 0.24)
        var combined = light
        combined.color = color.color
        combined.blackAndWhite = .init(enabled: true, intensity: 0, neutrals: 0.35, tone: -0.25)
        for p in [light, color, combined] {
            let native = read(try DevelopmentColorEngineV3.applyPointwise(p, to: source))
            for backend in [RAWMasterImageKernel.Backend.cpu, .gpu] {
                let plan = try PreviewPortableBasic.plan(p, backend: backend)
                let portable = try plan.render(width: 6, height: 1, rgba: pixels, coveragePlanes: [])
                XCTAssertNotEqual(portable, pixels)
                for i in native.indices {
                    if i % 4 == 3 {
                        XCTAssertEqual(portable[i].bitPattern, pixels[i].bitPattern)
                    } else {
                        XCTAssertEqual(native[i], portable[i], accuracy: 2e-6, "\(backend) component \(i)")
                    }
                }
                XCTAssertEqual(portable[8..<12], pixels[8..<12])
            }
        }
    }

    func testPortableBasicRequiresAnIsolatedPointPass() throws {
        var p = DevelopmentAdjustmentsV3()
        p.color = .init(enabled: true, saturation: 0.3)
        XCTAssertTrue(PreviewPortableBasic.qualifies(p))
        var withExposure = p
        withExposure.light = .init(enabled: true, exposure: 0.1)
        var withGrain = p
        withGrain.blackAndWhite.grain = 0.3
        var withGeometry = p
        withGeometry.geometry.straightenDegrees = 3
        for unsupported in [withExposure, withGrain, withGeometry] {
            XCTAssertFalse(PreviewPortableBasic.qualifies(unsupported))
            XCTAssertThrowsError(try PreviewPortableBasic.plan(unsupported))
        }
    }

    func testPortableCurvesAndLevelsApplyInV3Order() throws {
        let pixels: [Float] = [-0.04, 0.51, 1.25, 1, 0.18, 0.07, 0.12, 0.5, 0, 0, 0, 0,
                               0.35, 0.2, 0.41, 1, 0.04, 0.14, 0.23, 0.75, 0.0031308, 0.08, -0.0031308, 1]
        let source = floatImage(pixels)
        var curves = DevelopmentAdjustmentsV3()
        curves.curves = .init(enabled: true, rgb: .init(curve: .init(points: [
            .init(x: 0, y: 0.02), .init(x: 0.39, y: 0.48), .init(x: 1, y: 0.96)
        ]), inputBlack: 0.02, inputWhite: 0.97), red: .init(inputWhite: 0.92))
        var levels = DevelopmentAdjustmentsV3()
        levels.levels = .init(enabled: true, luminance: .manual(.init(
            black: 0.04, shadows: 0.25, midtones: 0.5, highlights: 0.5, white: 0.94, outputBlack: 0.03, outputWhite: 1)),
            blue: .manual(.init(black: 0.1, shadows: 0.23, midtones: 0.5, highlights: 0.8, white: 0.95,
                                outputBlack: 0.02, outputWhite: 0.96)))
        var combined = curves
        combined.levels = levels.levels
        combined.color = .init(enabled: true, saturation: 0.12, vibrance: 0.08, cast: -0.05)

        for p in [curves, levels, combined] {
            let basic = try DevelopmentColorEngineV3.applyPointwise(p, to: source)
            let native = read(try DevelopmentColorEngineV3.applyCurvesAndLevels(p, to: basic))
            for backend in [RAWMasterImageKernel.Backend.cpu, .gpu] {
                let plan = try PreviewPortableCurvesLevels.plan(p, backend: backend)
                let portable = try plan.render(width: 6, height: 1, rgba: pixels, coveragePlanes: [])
                XCTAssertNotEqual(portable, pixels)
                for i in portable.indices {
                    if i % 4 == 3 {
                        XCTAssertEqual(portable[i].bitPattern, pixels[i].bitPattern)
                    } else {
                        XCTAssertEqual(portable[i], native[i], accuracy: 2e-6, "\(backend) component \(i)")
                    }
                }
                XCTAssertEqual(portable[8..<12], pixels[8..<12])
            }
        }

        var natural = curves
        natural.curves.algorithm = .naturalCubicGamma512LumaV1
        XCTAssertFalse(PreviewPortableCurvesLevels.qualifies(natural))
        var withExposure = combined
        withExposure.light = .init(enabled: true, exposure: 0.25)
        XCTAssertFalse(PreviewPortableCurvesLevels.qualifies(withExposure))
    }

    private func floatImage(_ rgba: [Float]) -> CIImage {
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: data.count,
                       size: CGSize(width: rgba.count / 4, height: 1), format: .RGBAf,
                       colorSpace: DevelopmentColorEngineV3.linearSRGB)
    }

    private func read(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width)
        var value = [Float](repeating: 0, count: width * 4)
        DevelopmentColorEngineV3.context.render(image, toBitmap: &value, rowBytes: width * 16,
                                               bounds: image.extent, format: .RGBAf,
                                               colorSpace: DevelopmentColorEngineV3.linearSRGB)
        return value
    }
}
