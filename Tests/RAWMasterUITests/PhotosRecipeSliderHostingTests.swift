import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class PhotosRecipeSliderHostingTests: XCTestCase {
    func testContinuousTrackQuantizesOnlySliderInputAtOriginalStep() throws {
        XCTAssertEqual(try XCTUnwrap(PhotosSliderInput.snapped(123.456, range: 0...360, step: 0.01)), 123.46, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(PhotosSliderInput.snapped(-12.344, range: -100...100, step: 0.01)), -12.34, accuracy: 1e-12)
        XCTAssertEqual(PhotosSliderInput.snapped(-1, range: 0...360, step: 0.01), 0)
        XCTAssertEqual(PhotosSliderInput.snapped(400, range: 0...360, step: 0.01), 360)
        XCTAssertEqual(try XCTUnwrap(PhotosSliderInput.snapped(12345.678, range: 2000...50000, step: 0.01)), 12345.68, accuracy: 1e-10)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(PhotosSliderInput.snapped(invalid, range: -100...100, step: 0.01))
            XCTAssertNil(PhotosSliderInput.snapped(0, range: -100...100, step: invalid))
        }
        XCTAssertNil(PhotosSliderInput.snapped(0, range: -100...100, step: 0))
        // The existing text-field parse contract keeps finer input independently of slider step.
        XCTAssertEqual(try XCTUnwrap(DevelopmentNumericText.parse("123.456789", range: 0...360)), 123.456789)
    }
    func testLabelScrubUsesBoundedQuantizedTrackMappingWithoutTouchingSavedPrecision() throws {
        XCTAssertEqual(try XCTUnwrap(PhotosSliderInput.scrubbed(origin: 0.5, translation: 20, range: -2...2, step: 0.01)), 0.9, accuracy: 1e-12)
        XCTAssertEqual(PhotosSliderInput.scrubbed(origin: 0.5, translation: -1000, range: -2...2, step: 0.01), -2)
        XCTAssertEqual(PhotosSliderInput.scrubbed(origin: 0.5, translation: 1000, range: -2...2, step: 0.01), 2)
        XCTAssertNil(PhotosSliderInput.scrubbed(origin: .nan, translation: 2, range: -2...2, step: 0.01))
        XCTAssertNil(PhotosSliderInput.scrubbed(origin: 0, translation: .infinity, range: -2...2, step: 0.01))
        XCTAssertEqual(try DevelopmentNumericText.parse("0.123456789", range: -2...2), 0.123456789)
    }

    @MainActor func testNativeHostedAdvancedRangeSlidersHaveNoStepTicksOrRecipeWrites() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAXValue = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousAXValue, forAttribute: enhancedUI) }
        let original = DevelopmentRecipe()
        var recipe = original, writes = 0
        let session = EditingDevelopmentSession(readRecipe: { recipe }, commitRecipe: { next, _ in recipe = next; writes += 1 })
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64),
            exifOrientation: 1, orientedWidth: 120, orientedHeight: 80)
        let context = try session.activate(workID: "hosted-sliders", admissionFingerprint: String(repeating: "b", count: 64),
            source: source, sourceGeneration: 1, noiseReduction: .image)
        let definitions: [(String, Double, ClosedRange<Double>)] = [
            ("色相", 123.456789, 0...360), ("亮度", -12.3456789, -100...100),
            ("白色", 23.456789, -100...100), ("已有色温", 12345.6789, 2000...50000)]
        let host = NSHostingView(rootView: VStack {
            ForEach(definitions.indices, id: \.self) { index in
                let definition = definitions[index]
                PhotosRecipeValueRow(session: session, context: context, title: definition.0,
                    control: "legacy.host." + definition.0, value: definition.1, range: definition.2,
                    apply: { _, _ in XCTFail("Layout must not edit a recipe or quantize its saved value") },
                    onError: { _ in XCTFail("Native layout must not start an editing transaction") })
            }
        }.frame(width: 316))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 344, height: 440),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host
        host.frame = .init(x: 0, y: 0, width: 344, height: 440)
        host.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil); window.displayIfNeeded()
        func axValue(_ element: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        func accessibleSliders() -> [NSObject] {
            var pending: [NSObject] = [window], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
            while let node = pending.popLast(), visited.count < 512 {
                guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
                if (axValue(node, "accessibilityRole") as? String) == NSAccessibility.Role.slider.rawValue { result.append(node) }
                pending += ((axValue(node, "accessibilityChildren") as? [Any]) ?? []).compactMap { $0 as? NSObject }
            }
            return result
        }
        // Wait on actual controls, not an arbitrary delay or an offscreen view's empty hierarchy.
        let materialized = expectation(description: "four rendered accessible production sliders")
        let materialization = Task { @MainActor in
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if accessibleSliders().count == definitions.count { materialized.fulfill(); return }
                do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
            }
        }
        await fulfillment(of: [materialized], timeout: 3)
        materialization.cancel(); await materialization.value
        let actualSliders = accessibleSliders()
        XCTAssertEqual(actualSliders.count, definitions.count, "Empty or unmaterialized hosting must fail")
        XCTAssertEqual(Set(actualSliders.compactMap { axValue($0, "accessibilityLabel") as? String }), Set(definitions.map(\.0)))
        for slider in actualSliders { XCTAssertNotNil(axValue(slider, "accessibilityValue")) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0); XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        func sliders(_ view: NSView) -> [NSSlider] {
            (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders($0) }
        }
        let nativeSliders = sliders(host)
        print("Hosted continuous slider evidence: AX", actualSliders.count, "NSSlider", nativeSliders.count,
              "AX classes", actualSliders.map { String(describing: type(of: $0)) },
              "rendered", bitmap.pixelsWide, bitmap.pixelsHigh, "visible", window.isVisible)
        // SwiftUI may expose custom AX slider nodes instead of an NSSlider subclass. In that
        // case the four-role/render gate above still has to pass; zero controls never passes.
        for slider in nativeSliders {
            XCTAssertEqual(slider.numberOfTickMarks, 0, "Fine numeric precision must not allocate per-step tick layout")
            XCTAssertFalse(slider.allowsTickMarkValuesOnly)
        }
        XCTAssertEqual(recipe, original); XCTAssertEqual(writes, 0)
        XCTAssertNil(session.activeGesture); XCTAssertFalse(session.canUndo)
    }
}
