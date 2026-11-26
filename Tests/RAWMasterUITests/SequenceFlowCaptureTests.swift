import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class SequenceFlowCaptureTests: XCTestCase {
    @MainActor func testFilmstripCentersCardsAndKeepsGroupActionsIndependent() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        let fixture = try EditingWorkflowTests.Fixture(photoCount: 3)
        defer { fixture.clean() }
        let longName = "河谷日落延时拍摄 · Camera B 第 02 段"
        try fixture.store.createGroup(ids: fixture.assets.prefix(2).map(\.id), name: longName, kind: "连拍")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: fixture.assets[0].projectID)
        let segment = try XCTUnwrap(model.sequenceBrowserLayout.segments.first { $0.group != nil })
        let group = try XCTUnwrap(segment.group)
        let standalone = try XCTUnwrap(model.sequenceBrowserLayout.segments.first { $0.group == nil }?.assets.first)
        model.select(standalone)
        model.setMode(.single)

        let host = NSHostingView(rootView: FilmstripView().environmentObject(model).frame(width: 640))
        let size = host.fittingSize
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        func cardFrames(in view: NSView) -> [CGRect] {
            if view is CardInputView { return [view.convert(view.bounds, to: host)] }
            return view.subviews.flatMap { cardFrames(in: $0) }
        }
        func checkCards(_ count: Int) async throws {
            var cards: [CGRect] = []
            for _ in 0..<50 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                cards = cardFrames(in: host).filter { !$0.isEmpty }
                if cards.count == count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(cards.count, count)
            XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.5)
            for card in cards {
                XCTAssertEqual(card.midY, host.bounds.midY, accuracy: 0.5,
                               "Cards must be centered between the filmstrip's top and bottom edges")
            }
        }
        func press(_ id: String, expectedLabel: String? = nil) throws {
            let identifier = NSSelectorFromString("accessibilityIdentifier")
            let children = NSSelectorFromString("accessibilityChildren")
            var pending: [NSObject] = [window], seen = Set<ObjectIdentifier>()
            while let node = pending.popLast() {
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                if node.responds(to: identifier), node.perform(identifier)?.takeUnretainedValue() as? String == id {
                    if let expectedLabel {
                        let label = NSSelectorFromString("accessibilityLabel")
                        let value = node.responds(to: label) ? node.perform(label)?.takeUnretainedValue() as? String : nil
                        XCTAssertEqual(value, expectedLabel)
                    }
                    let action = NSSelectorFromString("accessibilityPerformPress")
                    let implementation = try XCTUnwrap(node.method(for: action))
                    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                    XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(node, action))
                    return
                }
                if node.responds(to: children) {
                    pending += node.perform(children)?.takeUnretainedValue() as? [NSObject] ?? []
                }
            }
            XCTFail("Missing accessibility element \(id)")
        }

        try await checkCards(3)
        let toggleID = "browser.filmstrip.group." + segment.id
        try press(toggleID, expectedLabel: "收起序列：\(longName)，当前段 2 张")
        try await checkCards(1)
        try press("group.properties." + group.id)
        XCTAssertTrue(model.showGroups)
        XCTAssertEqual(model.groupEditingID, group.id)
        XCTAssertEqual(model.groups.first { $0.id == model.groupEditingID }?.name, longName)
        model.showGroups = false
        try press(toggleID, expectedLabel: "展开序列：\(longName)，当前段 2 张")
        try await checkCards(3)
        XCTAssertEqual(model.focusedID, standalone.id)
        XCTAssertEqual(model.selectedIDs, [standalone.id])
        await model.editing?.shutdown()
    }

    @MainActor func testOptionalSequenceFlowCaptures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["RAWMASTER_SEQUENCE_FLOW_OUTPUT"],
              let imageDirectory = environment["RAWMASTER_SEQUENCE_FLOW_IMAGES"] else {
            throw XCTSkip("Set RAWMASTER_SEQUENCE_FLOW_OUTPUT and RAWMASTER_SEQUENCE_FLOW_IMAGES for packed sequence layout evidence")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        let source = output.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let images = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: imageDirectory), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
        XCTAssertFalse(images.isEmpty)
        guard !images.isEmpty else { return }
        for index in 0..<12 {
            try FileManager.default.copyItem(at: images[index % images.count], to: source.appendingPathComponent(String(format: "PHOTO-%02d.jpg", index)))
        }
        let library = output.appendingPathComponent("native-library.sqlite")
        let store = try LibraryStore(databaseURL: library)
        let session = try await ImportService(store: store).importDirectory(source: source, destination: nil,
            projectName: "连续排布 · 布局验证", mode: .reference, initialScreening: false, progress: { _ in })
        let suite = "SequenceFlowCapture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        model.selectScope(.project, id: session.projectID)
        let photos = model.browserAssets
        XCTAssertEqual(photos.count, 12)
        guard photos.count == 12 else { return }
        let a = try store.previewGroupCommand(.create(assetIDs: [1, 2, 3, 4, 10].map { photos[$0].id }, name: "河谷日落延时拍摄 · Camera B 第 02 段", kind: "连拍"))
        _ = try store.commitGroupCommand(a)
        let b = try store.previewGroupCommand(.create(assetIDs: [6, 7].map { photos[$0].id }, name: "短延时序列", kind: "延时"))
        _ = try store.commitGroupCommand(b)
        model.reload(); model.showSidebar = true; model.showInspector = false
        model.selectedIDs = [photos[0].id]; model.focusedID = photos[0].id; model.setMode(.grid)
        for (width, dark) in [(1100.0, false), (1280.0, false), (1100.0, true)] {
            try await capture(model, output: output, width: width, dark: dark, name: "grid-\(Int(width))-\(dark ? "dark" : "light")")
        }
        model.setMode(.single)
        try await capture(model, output: output, width: 1100, dark: false, name: "single-filmstrip")
        model.setMode(.grid); model.saveBrowse(); model.flushProjectReviewState()
        try JSONSerialization.data(withJSONObject: ["projectID": session.projectID, "photoIDs": photos.map(\.id),
            "library": library.path], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("fixture.json"))
    }

    @MainActor private func capture(_ model: AppModel, output: URL, width: Double, dark: Bool, name: String) async throws {
        let size = NSSize(width: width, height: 900)
        let host = NSHostingView(rootView: WorkbenchView().environmentObject(model)
            .preferredColorScheme(dark ? .dark : .light).environment(\.resolvedAppAppearance, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
