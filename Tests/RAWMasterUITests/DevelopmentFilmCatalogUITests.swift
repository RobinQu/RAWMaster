import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

@MainActor final class DevelopmentFilmCatalogUITests: XCTestCase {
    func testFilmDirectoryContainsAllNineStableIdentitiesAndTitlesWithoutRecords() throws {
        let films = DevelopmentPhotoFilterV3.allCases.filter(\.isSpektrafilm)
        XCTAssertEqual(films.count, 9)
        let folders = DevelopmentPresetDirectory.folders(records: [], favorites: [], looks: films,
            favoriteLooks: [], query: "")
        let directory = try XCTUnwrap(folders.first { $0.id == "film" })
        XCTAssertEqual(directory.count, 9)
        XCTAssertEqual(Set(directory.rows.map(\.id)), Set(films.map { "classic." + $0.rawValue }))
        XCTAssertEqual(Set(directory.rows.map(\.name)), Set(films.compactMap(\.spektrafilmTitle)))
        XCTAssertTrue(directory.children.isEmpty)
    }

    func testExpandedFilmSearchAndFavoritesKeepOriginalStableIdentity() throws {
        let films = DevelopmentPhotoFilterV3.allCases.filter(\.isSpektrafilm)
        for (query, look) in [("gold", DevelopmentPhotoFilterV3.spektraGold200UltraEndura),
                              ("Provia", .spektraProvia100F), ("500T", .spektraVision500T2383)] {
            let folders = DevelopmentPresetDirectory.folders(records: [], favorites: [], looks: films,
                favoriteLooks: [look], query: query, favoritesOnly: true)
            let directory = try XCTUnwrap(folders.first { $0.id == "film" })
            XCTAssertEqual(folders.map(\.id), ["film"])
            XCTAssertEqual(directory.rows.map(\.id), ["classic." + look.rawValue])
        }
        let empty = DevelopmentPresetDirectory.folders(records: [], favorites: [], looks: films,
            favoriteLooks: [], query: "没有这样的胶片")
        XCTAssertTrue(empty.isEmpty)
    }

    func testNewFilmsCanBeAdoptedAndUndoneInNativeSidebarWithoutChangingExposure() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend(filtersEnabled: true)
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: backend)
        app.selectScope(.project, id: fixture.assets[0].projectID)
        app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail(message)
            throw NSError(domain: "DevelopmentFilmCatalogUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        try await eventually("The film-capable editor did not open") {
            if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil && editing.availableDevelopmentFilters.contains(.spektraVision500T2383)
        }
        let context = try XCTUnwrap(editing.developmentContext)
        let session = editing.developmentSession
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.5
        let base = DevelopmentPresetRecord(id: "film-exposure", name: "曝光底稿", group: "测试", kind: .user, patch: patch)
        try session.adoptPreset(base, context: context, revision: session.revision)
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appending(path: "film-presets"))
        let host = NSHostingView(rootView: HStack {
            EditingLeftSidebar(editing: editing, presetCatalog: catalog)
            ScrollView { PhotosMaskControls(editing: editing, session: session, context: context) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 880),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderBack(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func element(_ id: String) -> NSObject? {
            var nodes: [NSObject] = [window]
            var seen = Set<ObjectIdentifier>()
            while let node = nodes.popLast() {
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                if attribute(node, "accessibilityIdentifier") as? String == id { return node }
                nodes += attribute(node, "accessibilityChildren") as? [NSObject] ?? []
            }
            return nil
        }
        func textField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "搜索名称或组" { return field }
            return view.subviews.lazy.compactMap { textField($0) }.first
        }
        let filmID = "editing.filter." + DevelopmentPhotoFilterV3.spektraPortra400Endura.rawValue
        try await eventually("Film catalog and search must be reachable") {
            element(filmID) != nil && element("editing.presets.search") != nil
        }
        let field = try XCTUnwrap(textField(host))
        func search(_ text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
            editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
        }
        let initialHistory = session.history.entryCount
        let newFilms: [DevelopmentPhotoFilterV3] = [.spektraGold200UltraEndura, .spektraPortra800SupraEndura,
            .spektraEktar100Endura, .spektraProvia100F, .spektraEktachrome100, .spektraVision500T2383]
        for (index, look) in newFilms.enumerated() {
            try search(try XCTUnwrap(look.spektrafilmTitle))
            let id = "editing.filter." + look.rawValue
            try await eventually("New film must be searchable: " + look.rawValue) { element(id) != nil }
            XCTAssertEqual(session.history.entryCount, initialHistory + index)
            let row = try XCTUnwrap(element(id))
            let press = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(row.responds(to: press)); _ = row.perform(press)
            try await eventually("Native adoption must commit the chosen film") {
                session.parameters.filter.selection == look && session.history.entryCount == initialHistory + index + 1
            }
            XCTAssertTrue(session.parameters.filter.enabled)
            XCTAssertEqual(session.parameters.filter.intensity, 100)
            XCTAssertEqual(session.parameters.light.exposure, 0.5)
        }
        try session.undo(context: context)
        XCTAssertEqual(session.parameters.filter.selection, .spektraEktachrome100)
        XCTAssertEqual(session.parameters.light.exposure, 0.5)
        let requests = await backend.thumbnailRequests
        XCTAssertFalse(requests.contains { $0.kind == .filters })
        try search("")
        try await eventually("Clearing search must restore the film catalog") { element(filmID) != nil }
        if let path = ProcessInfo.processInfo.environment["RAWMASTER_FILM_CATALOG_UI_OUTPUT"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, appearance, width) in [("native-dark", NSAppearance.Name.darkAqua, 780.0),
                                               ("native-light-narrow", .aqua, 620.0)] {
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: width, height: 880))
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try XCTUnwrap(CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                // The cached hosting view has transparent pixels where the window supplies material.
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(bounds)
                }
                context.draw(try XCTUnwrap(bitmap.cgImage), in: bounds)
                let capture = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                let data = try XCTUnwrap(capture.representation(using: .png, properties: [:]))
                try data.write(to: output.appending(path: name + ".png"), options: .atomic)
            }
        }
    }
}
