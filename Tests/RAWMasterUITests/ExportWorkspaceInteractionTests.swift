import AppKit
import ImageIO
import SwiftUI
import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

@MainActor
final class ExportWorkspaceInteractionTests: XCTestCase {
    func testFilterKeepsStableIDsAndExplicitLimitUsesCheckedInputOrder() throws {
        let assets = (0..<205).map { index in
            AssetRecord(id: String(index), sessionID: "session", projectID: "project", projectName: "沿岸",
                sourcePath: "/fixture/\(index).\(index.isMultiple(of: 2) ? "dng" : "jpg")",
                availability: index == 55 ? .missing : .available)
        }
        let order = assets.reversed().map(\.id)
        var state = ExportWorkspaceSelection()
        state.synchronize(order)
        XCTAssertEqual(state.checked.count, 205)
        state.checked.remove("204")
        state.focusedID = "55"
        let offline = ExportChecklistFilter.offline.rows(in: assets, query: "沿岸", checked: state.checked)
        XCTAssertEqual(offline.map(\.id), ["55"])
        let raw = ExportChecklistFilter.raw.rows(in: assets, query: "204", checked: state.checked)
        XCTAssertEqual(raw.map(\.id), ["204"])
        XCTAssertTrue(ExportChecklistFilter.checked.rows(in: raw, query: "", checked: state.checked).isEmpty)
        let jpeg = ExportChecklistFilter.jpeg.rows(in: assets, query: "55.jpg", checked: state.checked)
        state.checked.subtract(jpeg.map(\.id))
        XCTAssertTrue(state.checked.contains("203"))
        XCTAssertFalse(state.checked.contains("55"))
        state.synchronize(order)
        XCTAssertEqual(state.focusedID, "55")
        XCTAssertFalse(state.checked.contains("204"))
        state.checked = Set(order.filter { $0 != "204" })
        let retained = ExportWorkspaceSelection.keepingFirst(200, checked: state.checked, order: order)
        XCTAssertEqual(retained.count, 200)
        XCTAssertTrue(retained.contains("203"))
        XCTAssertTrue(retained.contains("4"))
        XCTAssertFalse(retained.contains("3"))
        XCTAssertFalse(retained.contains("204"))
    }

    func testRepeatedImportAndLastSettingsHaveIndependentLocalRecords() throws {
        let domain = "RAWMaster.ExportWorkshop." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let title = String(repeating: "山", count: 68) + "🌄"
        var original = ExportWorkspaceSettings()
        original.mode = "original"
        original.copyMode = "manifest"
        original.originalFormats = .rawOnly
        original.collision = "skip"
        let saved = try ExportWorkspacePresetLibrary.append(original.portable(named: title), to: defaults)
        let parsed = try PhotoExportPreset.read(original.portable(named: title).fileData())
        XCTAssertEqual(try ExportWorkspacePresetLibrary.matching(parsed, among: [saved])?.id, saved.id)

        var changed = original
        changed.sizeChoice = -1
        changed.customLongEdge = 1733
        changed.configuration.metadataPolicy = .rights
        changed.configuration.includeGPS = true
        let secondFile = changed.portable(named: title)
        XCTAssertNil(try ExportWorkspacePresetLibrary.matching(secondFile, among: [saved]))
        let name = ExportWorkspacePresetLibrary.availableName(title, among: [saved])
        XCTAssertLessThanOrEqual(name.utf16.count, 70)
        XCTAssertTrue(name.hasSuffix(" 2"))
        let second = try ExportWorkspacePresetLibrary.append(changed.portable(named: name), importedName: title, to: defaults)
        let restored = try ExportWorkspacePresetLibrary.records(in: defaults).map { try $0.choice() }
        XCTAssertEqual(try ExportWorkspacePresetLibrary.matching(secondFile, among: restored)?.id, second.id)
        XCTAssertEqual(restored.count, 2)
        try ExportWorkspacePresetLibrary.remember(changed, in: defaults)
        let last = try XCTUnwrap(ExportWorkspacePresetLibrary.last(in: defaults))
        XCTAssertEqual(last.settings.copyMode, "manifest")
        XCTAssertEqual(last.settings.originalFormats, .rawOnly)
        XCTAssertEqual(last.settings.resolvedConfiguration.maximumLongEdge, 1733)
        XCTAssertEqual(last.settings.configuration.includeGPS, true)
        XCTAssertEqual(try ExportWorkspacePresetLibrary.records(in: defaults).count, 2)
        XCTAssertTrue(ExportWorkspacePresetChoice.builtins.allSatisfy { $0.settings.configuration.metadataPolicy == .rights })
    }

    func testChangingStyleKeepsPersonalContentAndReplacesGeometry() throws {
        var imported = PhotoExportAppearance(style: .paper, signature: "岸线工作室")
        imported.ratio = "16:9"
        imported.anchor = "br"
        imported.mark = "off"
        imported.logo = .init(sha256: String(repeating: "0", count: 64), base64: "")
        let changed = ExportLayoutControls.choosing(.mist, for: .init(appearance: imported))
        XCTAssertEqual(changed.resolvedAppearance.ratio, "4:5")
        XCTAssertEqual(changed.resolvedAppearance.anchor, "bc")
        XCTAssertEqual(changed.signature, "岸线工作室")
        XCTAssertEqual(changed.resolvedAppearance.logo, imported.logo)
        let plain = ExportLayoutControls.choosing(.plain, for: changed)
        XCTAssertEqual(plain.resolvedAppearance.mark, "off")
        XCTAssertEqual(plain.resolvedAppearance.logo, imported.logo)
        XCTAssertNil(ExportLayoutControls.issue(for: plain))
        XCTAssertNil(ExportLayoutControls.issue(for: .init(style: .paper)))
        XCTAssertNotNil(ExportLayoutControls.issue(for: .init(style: .sign)))
    }

    func testNativeStyleCardsCancelApplyAndWriteCurrentPhoto() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        let source = fixture.source.appendingPathComponent("coast.jpg")
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let cameraPhoto = tests.appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/dji187-context376/files/asset0000.jpg")
        try FileManager.default.copyItem(at: cameraPhoto, to: source)
        _ = try await ImportService(store: fixture.store).importDirectory(source: fixture.source, destination: nil,
            projectName: "沿岸", mode: .reference, progress: { _ in })
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let asset = try XCTUnwrap(model.assets.first)
        model.workbenchExportContext = .photo(id: asset.id)
        model.activateWorkflow(.export)
        let output = fixture.root.appendingPathComponent("exports")
        fixture.defaults.set(output.path, forKey: "rawmaster.export.workspace.destination.v1")
        let host = NSHostingView(rootView: ExportWorkspace(defaults: fixture.defaults).environmentObject(model)
            .frame(width: 1120, height: 740))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        for style in BuiltinPhotoStyle.allCases {
            _ = try await element("export.workspace.style." + style.rawValue, in: window)
        }
        try await press("export.workspace.style.paper", in: window)
        XCTAssertNil(window.attachedSheet)
        try await captureIfRequested("native-workspace", window: window)
        try await press("export.workspace.style.sign", in: window)
        _ = try await element("export.style.signature", in: window)
        try await press("export.style.cancel", in: window)
        try await wait("dismiss cancelled draft") { window.attachedSheet == nil }
        try await press("export.workspace.style.edit", in: window)
        for style in BuiltinPhotoStyle.allCases {
            _ = try await element("export.style." + style.rawValue, in: window)
        }
        try await press("export.style.mist", in: window)
        try await captureIfRequested("native-watermark", window: window)
        try await press("export.style.apply", in: window)
        try await wait("apply edited style") { window.attachedSheet == nil }
        model.openExportWorkspace(.original)
        try await wait("consume original menu command") { model.requestedWorkbenchExportMode == nil }
        model.openExportWorkspace(.render)
        try await wait("consume render menu command") { model.requestedWorkbenchExportMode == nil }
        try await press("export.workspace.preset.new", in: window)
        try await press("export.workspace.preset.save", in: window)
        try await wait("save edited preset") { window.attachedSheet == nil }
        let saved = try ExportWorkspacePresetLibrary.records(in: fixture.defaults).map { try $0.choice() }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.settings.configuration.layout.style, .mist)
        XCTAssertEqual(saved.first?.settings.mode, "render")
        XCTAssertEqual(fixture.defaults.string(forKey: "rawmaster.export.workspace.destination.v1"), output.path)

        try await press("export.workspace.confirm", in: window)
        let file = output.appendingPathComponent("coast-0001.jpg")
        try await wait("write selected output") { FileManager.default.fileExists(atPath: file.path) }
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertEqual(pixels.width, 768)
        XCTAssertEqual(pixels.height, 960)
        XCTAssertEqual(try ExportWorkspacePresetLibrary.last(in: fixture.defaults)?.settings.configuration.layout.style, .mist)
        await model.editing?.shutdown()
    }

    private func captureIfRequested(_ name: String, window: NSWindow) async throws {
        guard let location = ProcessInfo.processInfo.environment["RAWMASTER_EXPORT_CAPTURE_DIRECTORY"] else { return }
        // Let the AppKit sheet finish its transition before sampling the composited window.
        try await Task.sleep(nanoseconds: 450_000_000)
        let captured = window.attachedSheet ?? window
        let view = try XCTUnwrap(captured.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let foreground = try XCTUnwrap(bitmap.cgImage)
        let pixels = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let composite = try XCTUnwrap(CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        captured.effectiveAppearance.performAsCurrentDrawingAppearance {
            composite.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(1).cgColor)
            composite.fill(pixels)
        }
        composite.draw(foreground, in: pixels)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(composite.makeImage())).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: location, isDirectory: true).appendingPathComponent(name + ".png"))
    }

    private func wait(_ description: String, _ check: () -> Bool) async throws {
        for _ in 0..<300 {
            if check() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for " + description)
        throw NSError(domain: "ExportWorkspaceInteractionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for " + description])
    }

    private func element(_ id: String, in window: NSWindow) async throws -> NSObject {
        var result: NSObject?
        var lastIDs = [String]()
        defer { if result == nil { print("Export window elements while waiting for", id, lastIDs) } }
        try await wait(id) {
            var queue: [NSObject] = [window.attachedSheet ?? window]
            var seen = Set<ObjectIdentifier>()
            lastIDs.removeAll(keepingCapacity: true)
            while let value = queue.popLast() {
                guard seen.insert(ObjectIdentifier(value)).inserted else { continue }
                func attribute(_ name: String) -> Any? {
                    let selector = NSSelectorFromString(name)
                    return value.responds(to: selector) ? value.perform(selector)?.takeUnretainedValue() : nil
                }
                if let identifier = attribute("accessibilityIdentifier") as? String {
                    let label = attribute("accessibilityLabel") as? String ?? attribute("accessibilityValue") as? String ?? ""
                    lastIDs.append(identifier + " " + label)
                    if identifier == id { result = value; return true }
                }
                queue += attribute("accessibilityChildren") as? [NSObject] ?? []
            }
            return false
        }
        return try XCTUnwrap(result, id)
    }

    private func press(_ id: String, in window: NSWindow) async throws {
        let element = try await element(id, in: window)
        let press = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: press), id)
        let implementation = try XCTUnwrap(element.method(for: press))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(element, press), id)
    }

}
