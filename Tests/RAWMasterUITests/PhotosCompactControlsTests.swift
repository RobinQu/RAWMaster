import AppKit
import SwiftUI
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class PhotosCompactControlsTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for compact control input")
    }

    @MainActor private func axValue(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func axPoint(_ value: Any?) -> CGPoint? {
        guard let value else { return nil }
        let reference = value as! AXValue
        var point = CGPoint.zero
        return AXValueGetValue(reference, .cgPoint, &point) ? point : nil
    }
    private func axSize(_ value: Any?) -> CGSize? {
        guard let value else { return nil }
        let reference = value as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(reference, .cgSize, &size) ? size : nil
    }

    @MainActor private func accessibleElements(_ window: NSWindow) -> [NSObject] {
        var pending: [NSObject] = [window], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let node = pending.popLast(), visited.count < 1_024 {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            pending += ((axValue(node, "accessibilityChildren") as? [Any]) ?? []).compactMap { $0 as? NSObject }
        }
        return result
    }

    @MainActor func testCompactScalarRowDoubleClickResetsOnlyItsOwnField() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAXValue = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousAXValue, forAttribute: enhancedUI) }
        var parameters = DevelopmentAdjustmentsV3()
        parameters.light = .init(enabled: true, exposure: 0.5, contrast: 0.2)
        parameters.color = .init(enabled: true, vibrance: 0.15)
        var recipe = DevelopmentRecipe(adjustmentsV3: parameters)
        var writes = 0
        let session = EditingDevelopmentSession(readRecipe: { recipe }, commitRecipe: { next, _ in
            recipe = next; writes += 1
        })
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64),
            exifOrientation: 1, orientedWidth: 1200, orientedHeight: 800)
        let context = try session.activate(workID: "compact-controls", admissionFingerprint: String(repeating: "b", count: 64),
            source: source, sourceGeneration: 1, noiseReduction: .image)
        let host = NSHostingView(rootView: PhotosScalarAdjustmentControls(session: session, context: context,
            group: .light, onError: { XCTFail("Compact control error: \($0)") }).padding(12))
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 340, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return accessibleElements(window).filter {
                axValue($0, "accessibilityRole") as? String == NSAccessibility.Role.slider.rawValue
            }.count == 8
        }
        let elements = accessibleElements(window)
        let sliders = elements.filter { axValue($0, "accessibilityRole") as? String == NSAccessibility.Role.slider.rawValue }
        let editors = elements.filter { axValue($0, "accessibilityRole") as? String == NSAccessibility.Role.textField.rawValue }
        XCTAssertEqual(sliders.count, 8)
        XCTAssertEqual(editors.count, 8)
        XCTAssertEqual(writes, 0)

        let label = try XCTUnwrap(elements.first {
            let text = (axValue($0, "accessibilityValue") as? String) ?? (axValue($0, "accessibilityLabel") as? String)
            return axValue($0, "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue && text == "曝光"
        })
        let actions = try XCTUnwrap(axValue(label, "accessibilityCustomActions") as? [NSAccessibilityCustomAction])
        let reset = try XCTUnwrap(actions.first { $0.name == "复位曝光" })
        XCTAssertNotNil(reset.handler)
        reset.handler?()
        try await wait { recipe.adjustmentsV3?.light.exposure == 0 }
        XCTAssertEqual(recipe.adjustmentsV3?.light.contrast, 0.2)
        XCTAssertEqual(recipe.adjustmentsV3?.color.vibrance, 0.15)
        XCTAssertTrue(recipe.adjustmentsV3?.light.enabled == true)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(session.history.entryCount, 1)
        XCTAssertNil(session.activeGesture)
    }

    func testColorScalarControlsUseExplicitDisplayMappingWithoutChangingRecipeUnits() {
        for field in PhotosScalarField.fields(for: .color, noiseReduction: .image) where field.id == "saturation" || field.id == "vibrance" {
            XCTAssertEqual(field.displayRange, -100...100)
            XCTAssertEqual(field.displayScale, 100)
            XCTAssertEqual(field.displayed(0.25), 25)
            XCTAssertEqual(field.recipeValue(-40), -0.4)
            XCTAssertEqual(field.range, -1...2, "Legacy recipe range must not be rewritten")
        }
    }
}
