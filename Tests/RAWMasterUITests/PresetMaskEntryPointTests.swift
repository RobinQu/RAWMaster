import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

@MainActor final class PresetMaskEntryPointTests: XCTestCase {
    private func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func element(_ id: String, in window: NSWindow) -> NSObject? {
        var nodes: [NSObject] = [window]
        var seen = Set<ObjectIdentifier>()
        while let node = nodes.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if attribute(node, "accessibilityIdentifier") as? String == id { return node }
            nodes += attribute(node, "accessibilityChildren") as? [NSObject] ?? []
        }
        return nil
    }

    private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < limit {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(message)
        throw NSError(domain: "PresetMaskEntryPointTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let input = view as? NSTextField, input.placeholderString == "搜索名称或组" { return input }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    private func press(_ id: String, in window: NSWindow) throws {
        let row = try XCTUnwrap(element(id, in: window), id)
        let action = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(row.responds(to: action))
        _ = row.perform(action)
    }

    private func search(_ query: String, field: NSTextField, window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
    }

    func testSearchFindsAndAppliesPresetInWindowAlongsideMaskControls() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let backend = PhotosDevelopmentBackend()
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: backend)
        app.selectScope(.project, id: fixture.assets[0].projectID)
        app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        try await eventually("The normal editor did not open") {
            if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil
        }
        let context = try XCTUnwrap(editing.developmentContext)
        let session = editing.developmentSession
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appendingPathComponent("test-presets"))
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.375
        var records = (0..<1075).map { i in
            DevelopmentPresetRecord(id: "sample-\(i)", name: "样片预设 \(i)", group: "组 \(i/25)",
                                    kind: .user, patch: patch)
        }
        var savedParameters = session.parameters
        savedParameters.light.enabled = true
        savedParameters.light.exposure = 0.625
        let full = try DevelopmentPresetPatch(fullRecipe: .init(adjustmentsV3: savedParameters),
                                              sourceID: XCTUnwrap(session.source?.sourceContentID))
        records[0] = .init(id: "full", name: "整图还原", group: "单张", kind: .user, patch: full)
        _ = try catalog.importBatch(records, originals: [:])
        let host = NSHostingView(rootView: HStack {
            EditingLeftSidebar(editing: editing, presetCatalog: catalog)
            ScrollView { PhotosMaskControls(editing: editing, session: session, context: context) }
        }.frame(width: 780, height: 880))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 880),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await eventually("The new-mask entry must be reachable in the window") {
            self.element("photos.mask.create", in: window) != nil
        }
        try press("photos.mask.create", in: window)
        try await eventually("Preset search and mask tools must be reachable in the window") {
            ["editing.presets.search", "editing.presets.create", "photos.mask.subject", "photos.mask.brush"].allSatisfy {
                self.element($0, in: window) != nil
            }
        }
        let initialHistory = session.history.entryCount
        let field = try XCTUnwrap(textField(in: host))
        try search("样片预设 1074", field: field, window: window)
        try await eventually("Searching the mounted catalog must expose the final record") {
            self.element("editing.preset.sample-1074", in: window) != nil
        }
        XCTAssertNil(element("editing.preset.sample-1073", in: window))
        XCTAssertEqual(session.history.entryCount, initialHistory)
        try press("editing.preset.sample-1074", in: window)
        try await eventually("The accessible row must use the editing transaction") {
            session.parameters.light.exposure == 0.375 && session.history.entryCount == initialHistory + 1
        }
        let beforeFull = session.recipe
        try search("整图还原", field: field, window: window)
        try await eventually("Full recipe must be searchable") { self.element("editing.preset.full", in: window) != nil }
        try press("editing.preset.full", in: window)
        try await eventually("Selecting a full recipe must expose preview and adopt independently") {
            self.element("editing.presets.previewFull", in: window) != nil && self.element("editing.presets.adoptFull", in: window) != nil
        }
        XCTAssertEqual(session.recipe, beforeFull)
        try press("editing.presets.previewFull", in: window)
        try await eventually("Explicit full preview should own the temporary canvas") { editing.hoveredPresetID == "full" }
        XCTAssertEqual(session.recipe, beforeFull)
        try press("editing.presets.previewFull", in: window)
        try await eventually("Ending preview should restore the committed recipe") { editing.hoveredPresetID == nil }
        XCTAssertEqual(session.history.entryCount, initialHistory + 1)
        try press("editing.presets.adoptFull", in: window)
        try await eventually("Only explicit adoption should replace a full recipe") {
            session.parameters.light.exposure == 0.625 && session.history.entryCount == initialHistory + 2
        }
        try session.undo(context: context)
        XCTAssertEqual(session.recipe, beforeFull)
        let requests = await backend.thumbnailRequests
        XCTAssertFalse(requests.contains { $0.kind == .filters }, "Browsing, filtering and adopting must not request filter tiles")
    }

    func testUnifiedDirectoryCancelsPreparationWhenCollapsedAndRestoresOnReopen() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appending(path: "switch-presets"))
        var patch = DevelopmentPresetPatch()
        patch.semanticMasks = [try DevelopmentPresetMaskIntent(target: .subject, name: "主体", adjustments: .init(exposure: 0.4))]
        let record = DevelopmentPresetRecord(id: "fixture-subject", name: "人物选区", group: "个人预设", kind: .user, patch: patch)
        var exposure = DevelopmentPresetPatch()
        exposure.exposure = 0.3
        let hoverRecord = DevelopmentPresetRecord(id: "fixture-light", name: "提亮", group: "个人预设", kind: .user, patch: exposure)
        _ = try catalog.importBatch([record, hoverRecord], originals: [:])
        func openEditor() async throws -> (app: AppModel, editing: EditingController, context: EditingInteractionContext) {
            let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                               editingPreviewBackend: PhotosDevelopmentBackend(filtersEnabled: true))
            app.selectScope(.project, id: fixture.assets[0].projectID)
            app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
            let editing = try XCTUnwrap(app.editing)
            try await eventually("Opening editor with filter capability") {
                if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
                return editing.developmentContext != nil && editing.availableDevelopmentFilters.contains(.vivid)
            }
            return (app, editing, try XCTUnwrap(editing.developmentContext))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func mount(_ editing: EditingController, _ context: EditingInteractionContext) {
            let host = NSHostingView(rootView: HStack {
                EditingLeftSidebar(editing: editing, presetCatalog: catalog)
                ScrollView { PhotosMaskControls(editing: editing, session: editing.developmentSession, context: context) }
            }.frame(width: 780, height: 850))
            window.contentView = host; window.orderBack(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        let first = try await openEditor(), editing = first.editing
        let initial = editing.recipe, history = editing.developmentSession.history.entryCount
        let entered = expectation(description: "Semantic preparation entered")
        let cancelled = expectation(description: "Leaving catalog cancelled its model task")
        editing.developmentMaskInput = EditingMaskInputSession(editing: editing, generate: { _,_,_,_ in
            entered.fulfill()
            do { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
            catch { if Task.isCancelled { cancelled.fulfill() }; throw error }
        })
        mount(editing, first.context)
        try await eventually("The new-mask entry must be reachable in the window") {
            self.element("photos.mask.create", in: window) != nil
        }
        try press("photos.mask.create", in: window)
        try await eventually("The text directory and the right-hand masks appear together") {
            self.element("editing.presets.search", in: window) != nil && self.element("editing.presets.folder.classic", in: window) != nil
                && self.element("photos.mask.subject", in: window) != nil
        }
        try press("editing.presets.folder.classic", in: window)
        try await eventually("Basic filters remain reachable") { self.element("editing.filter.favorite.vivid", in: window) != nil }
        XCTAssertNil(element("editing.filters.browserMode", in: window))
        XCTAssertNil(element("photos.filters.thumbnail.retry", in: window))
        try press("editing.filter.favorite.vivid", in: window)
        XCTAssertTrue(editing.favoriteDevelopmentFilters.contains(.vivid))
        editing.developmentMaskInput.select(.linear, context: first.context)
        XCTAssertEqual(editing.developmentMaskInput.activeKind, .linear)
        editing.previewDevelopmentFilter(.vivid, context: first.context)
        XCTAssertNotNil(editing.hoveredPresetID)
        let host = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(textField(in: host))
        try search(record.name, field: field, window: window)
        try await eventually("The semantic preset is searchable") { self.element("editing.preset.fixture-subject", in: window) != nil }
        try press("editing.preset.fixture-subject", in: window)
        try await eventually("Semantic selection requires an explicit preparation") { self.element("editing.presets.prepareMasks", in: window) != nil }
        try press("editing.presets.prepareMasks", in: window)
        await fulfillment(of: [entered], timeout: 3)
        editing.previewDevelopmentPreset(hoverRecord, context: first.context)
        XCTAssertEqual(editing.hoveredPresetID, hoverRecord.id)
        try press("editing.leftRail.filters", in: window)
        await fulfillment(of: [cancelled], timeout: 3)
        try await eventually("Collapsing removes the directory from the accessibility tree") {
            self.element("editing.presets.search", in: window) == nil
        }
        XCTAssertEqual(editing.recipe, initial); XCTAssertEqual(editing.developmentSession.history.entryCount, history)
        XCTAssertNil(editing.hoveredPresetID)
        XCTAssertEqual(editing.developmentMaskInput.activeKind, .linear)
        XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        window.contentView = nil; await editing.shutdown(finishPreviews: false)
        let reopened = try await openEditor()
        mount(reopened.editing, reopened.context)
        try await eventually("A fresh editor uses the same directory") {
            self.element("editing.presets.search", in: window) != nil
        }
        XCTAssertTrue(reopened.editing.favoriteDevelopmentFilters.contains(.vivid))
        XCTAssertEqual(reopened.editing.recipe, initial)
        XCTAssertNil(reopened.editing.hoveredPresetID)
        window.contentView = nil; await reopened.editing.shutdown(finishPreviews: false)
    }

    func testImportedPresetPreviewsMappedFieldsWithoutCommitting() async throws {
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        app.selectScope(.project, id: fixture.assets[0].projectID)
        app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        try await eventually("The photo must admit native adjustment previews") {
            if editing.work != nil && editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil && editing.previews.primary.frame?.quality == .settled
        }
        let context = try XCTUnwrap(editing.developmentContext)
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appendingPathComponent("hover-presets"))
        let url = fixture.root.appendingPathComponent("Mapped.xmp")
        try Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <r:Description xmlns:c="http://ns.adobe.com/camera-raw-settings/1.0/"
              c:PresetType="Normal" c:ProcessVersion="15.4" c:Exposure2012="1" c:FutureOperator="9"/>
            </r:RDF></x:xmpmeta>
            """.utf8).write(to: url)
        let stage = try DevelopmentPresetExchange.inspectFiles([url], catalog: catalog)
        _ = try stage.commit(to: catalog)
        let row = try XCTUnwrap(catalog.records().first)
        XCTAssertFalse(row.blockingReasons.isEmpty)
        let preview = try XCTUnwrap(editing.presetForHover(row, context: context))
        let before = editing.recipe, entries = editing.developmentSession.history.entryCount
        func red(_ image: NSImage) throws -> CGFloat {
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let color = try XCTUnwrap(bitmap.colorAt(x: cgImage.width / 2, y: cgImage.height / 2)?.usingColorSpace(.sRGB))
            return color.redComponent
        }
        let committed = try XCTUnwrap(editing.previews.primary.frame)
        let baseRed = try red(committed.image)
        editing.previewDevelopmentPreset(preview, context: context, explicit: true)
        try await eventually("Imported XMP should reach the temporary canvas") { editing.filterHoverFrame != nil }
        let displayed = try XCTUnwrap(editing.filterHoverFrame)
        XCTAssertEqual(displayed.quality, .settled)
        XCTAssertGreaterThan(try red(displayed.image), baseRed + 0.01)
        XCTAssertEqual(editing.previews.primary.frame?.id, committed.id)
        XCTAssertEqual(editing.recipe, before)
        XCTAssertEqual(editing.developmentSession.history.entryCount, entries)
        editing.cancelPresetHover(id: row.id)
        XCTAssertNil(editing.filterHoverFrame)
        XCTAssertThrowsError(try editing.developmentSession.adoptPreset(row, context: context,
            revision: editing.developmentSession.revision))
        await editing.shutdown(finishPreviews: false)
    }

    func testUnreadablePresetCatalogReportsToItsPhotoAndPreservesExistingNotices() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let first = fixture.assets[0], second = fixture.assets[1]
        app.selectScope(.project, id: first.projectID)
        app.select(first); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        try await eventually("The editing context should be ready before loading the catalog") {
            if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil
        }
        editing.postNotice("保留已有消息", for: first.id)
        let path = fixture.root.appendingPathComponent("unreadable-catalog")
        try Data().write(to: path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditingLeftSidebar(editing: editing, presetCatalog: .init(root: path)))
        defer { window.orderOut(nil); window.close() }
        window.orderBack(nil)
        try await eventually("Unreadable catalog should post a per-photo error without opening an alert") {
            editing.photoNotices.contains { $0.text.hasPrefix("无法读取滤镜目录") && $0.kind == .error && $0.assetID == first.id }
        }
        let failure = try XCTUnwrap(editing.photoNotices.first { $0.kind == .error && $0.text.hasPrefix("无法读取滤镜目录") })
        XCTAssertNil(window.attachedSheet)
        window.contentView = nil
        editing.focus(second)
        XCTAssertFalse(editing.photoNotices.contains(failure))
        editing.focus(first)
        XCTAssertTrue(editing.photoNotices.contains(failure))
        editing.dismissNotice(failure.id)
        XCTAssertTrue(editing.photoNotices.contains { $0.text == "保留已有消息" })
        await editing.shutdown(finishPreviews: false)
    }

    func testScenePresetDirectorySupportsSearchAndKeepsSDRControlsReadOnly() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appendingPathComponent("hdr-directory"))
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.4
        let imported = try catalog.create(name: "自定义天空", group: "个人", patch: patch)
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let host = NSHostingView(rootView: ScrollView {
            ScenePresetDirectory(catalog: catalog, sectionExpanded: .constant(true), favoriteLooks: [.vivid]) {
                XCTFail("Failed to read the fixture catalog: \($0)")
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await eventually("The HDR directory should expose four browsable categories") {
            ["adaptive","classic","film","imported"].allSatisfy { self.element("editing.presets.folder." + $0, in: window) != nil }
        }
        let field = try XCTUnwrap(textField(in: host))
        try search(imported.name, field: field, window: window)
        try await eventually("Search should narrow the HDR tree to the matching source folder") {
            self.element("editing.presets.folder.imported", in: window) != nil && self.element("editing.presets.folder.film", in: window) == nil
        }
        XCTAssertNil(element("editing.preset." + imported.id, in: window))
        XCTAssertNil(element("editing.filters.amount", in: window))
        XCTAssertNil(element("editing.presets.adoptFull", in: window))
        XCTAssertEqual(try catalog.snapshot().records, [imported])
    }

    func testAllScopedAdobeRowsHaveChineseDisplayLabelsAndKeepTheirOriginalNames() throws {
        struct Manifest: Decodable {
            struct Entry: Decodable { let id, name, sourceRoot, sourceRelativePath: String }
            let entries: [Entry]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("specs/031-preset-browser/contracts/migration-manifest-v1.json")
        let entries = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file)).entries.filter { $0.sourceRoot == "systemCameraRawSettings" }
        XCTAssertEqual(entries.count, 53)
        for entry in entries {
            let row = DevelopmentPresetRecord(id: entry.id, name: entry.name, group: "Adaptive", kind: .imported,
                patch: DevelopmentPresetPatch(), metadata: ["origin": "adobeBuiltin", "relativePath": entry.sourceRelativePath])
            XCTAssertNotNil(DevelopmentPresetDirectory.displayName(row).range(of: "[\u{4e00}-\u{9fff}]", options: .regularExpression), entry.sourceRelativePath)
            XCTAssertEqual(row.name, entry.name)
            XCTAssertEqual(DevelopmentPresetBrowserItem.record(row).id, entry.id)
        }
    }

    func testDirectoryKeepsSourceAdaptiveGroupsAheadOfImportedFolders() {
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.5
        let sky = DevelopmentPresetRecord(id: "sky", name: "Adaptive Sky - Sunrise", group: "Mixed", kind: .imported, patch: patch,
            metadata: ["origin": "adobeBuiltin", "relativePath": "Premium/Adaptive - Sky/Sunrise.xmp"])
        let portrait = DevelopmentPresetRecord(id: "portrait", name: "Warm", group: "Mixed", kind: .imported, patch: patch,
            metadata: ["origin": "adobeBuiltin", "relativePath": "Premium/Adaptive - Portrait/Warm.xmp"])
        let user = DevelopmentPresetRecord(id: "user", name: "Adaptive Sky - Sunrise", group: "Personal", kind: .imported, patch: patch)
        let folders = DevelopmentPresetDirectory.folders(records: [sky, portrait, user], favorites: [],
            looks: [.original, .spektraPortra400Endura], favoriteLooks: [], query: "")
        XCTAssertEqual(folders.map(\.name), ["自适应滤镜", "基础滤镜", "胶片模拟", "用户导入滤镜"])
        XCTAssertEqual(folders.first?.children.map(\.name), ["人像", "天空"])
        XCTAssertEqual(DevelopmentPresetDirectory.displayName(sky), "日出")
        XCTAssertEqual(DevelopmentPresetDirectory.displayName(user), "Adaptive Sky - Sunrise")
        XCTAssertEqual(folders.first?.children.map(\.id), ["adaptive.Portrait", "adaptive.Sky"])
        XCTAssertEqual(folders.first(where: { $0.id == "imported" })?.children.map(\.name), ["Personal"])
        let search = DevelopmentPresetDirectory.folders(records: [sky, portrait, user], favorites: [],
            looks: [], favoriteLooks: [], query: "日出")
        XCTAssertEqual(search.first?.children.flatMap(\.rows).map(\.id), ["sky"])
    }

    func testQuickPromptDockReplacesCanvasControlsInTheNativeWindow() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        app.selectScope(.project, id: fixture.assets[0].projectID)
        app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        try await eventually("The normal editing work is ready") { editing.canOpenQuickPrompt }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: EditingImageCanvas(editing: editing).environmentObject(app).frame(width: 1100, height: 720))
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await eventually("Quick Prompt is reachable on the original dock") { self.element("editing.quickPrompt.open", in: window) != nil }
        XCTAssertNotNil(element("editing.fit", in: window))
        try press("editing.quickPrompt.open", in: window)
        try await eventually("Expanded dock contains editing controls and removes the old ones") {
            self.element("editing.quickPrompt.text", in: window) != nil && self.element("editing.fit", in: window) == nil
        }
        XCTAssertNotNil(element("editing.quickPrompt.scopeMenu", in: window))
        XCTAssertNotNil(element("editing.quickPrompt.rectangle", in: window))
        XCTAssertNotNil(element("editing.quickPrompt.whole", in: window))
        try press("editing.quickPrompt.rectangle", in: window)
        XCTAssertTrue(editing.quickPromptSelecting)
        editing.setQuickPromptScope(.rectangle(.init(x: 0.2, y: 0.3, width: 0.4, height: 0.5)))
        try press("editing.quickPrompt.whole", in: window)
        XCTAssertFalse(editing.quickPromptSelecting)
        XCTAssertNotNil(element("editing.quickPrompt.model", in: window))
        XCTAssertTrue(editing.jobs.isEmpty)
        XCTAssertEqual(editing.quickPromptDraft.selection, .whole)
        try press("editing.quickPrompt.close", in: window)
        try await eventually("Closing restores the existing canvas controls") {
            self.element("editing.fit", in: window) != nil && self.element("editing.quickPrompt.text", in: window) == nil
        }
        await editing.shutdown(finishPreviews: false)
    }
}
