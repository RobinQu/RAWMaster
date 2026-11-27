import AppKit
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class WorkbenchActivityTests: XCTestCase {
    @MainActor func testEachActivityTabHasAnAccessibleListAndReadableEntries() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let fixture = try ProjectReviewUITests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.errorMessage = "后台测试操作失败"
        model.progress = TaskProgress(title: "扫描照片文件", completed: 2, total: 4, message: "扫描中")
        let host = NSHostingView(rootView: WorkbenchActivityWindow(model: model))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 445, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func attribute(_ value: NSObject, _ key: String) -> Any? {
            let selector = NSSelectorFromString(key)
            return value.responds(to: selector) ? value.perform(selector)?.takeUnretainedValue() : nil
        }
        func nodes(in root: NSObject) -> [NSObject] {
            var pending = [root], visited = Set<ObjectIdentifier>(), results = [NSObject]()
            while let next = pending.popLast() {
                guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
                results.append(next)
                pending += attribute(next, "accessibilityChildren") as? [NSObject] ?? []
            }
            return results
        }
        func element(_ id: String) async throws -> NSObject {
            for _ in 0..<200 {
                host.layoutSubtreeIfNeeded()
                if let result = nodes(in: window).first(where: { attribute($0, "accessibilityIdentifier") as? String == id }) {
                    return result
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LibraryError.invalid("Missing AX element " + id)
        }
        _ = try await element("workbench.activity.window")
        _ = try await element("workbench.activity.close")
        _ = try await element("workbench.activity.tabs")
        for (tab, text) in [("notices", "后台测试操作失败"), ("tasks", "扫描照片文件"), ("logs", "已打开资料库")] {
            let radio = try await element("workbench.activity." + tab)
            let press = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(radio.responds(to: press))
            _ = radio.perform(press)
            let list = try await element("workbench.activity.list." + tab)
            let labels = nodes(in: list).flatMap { item in
                ["accessibilityLabel", "accessibilityValue"].compactMap { attribute(item, $0) as? String }
            }
            XCTAssertTrue(labels.contains { $0.contains(text) }, "\(tab) entries were not readable: \(labels)")
        }
        await model.editing?.shutdown(finishPreviews: false)
    }

    @MainActor func testConcurrentLiveSourcesAndPublicLifecycleLogsStayInTheirLibrary() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        let other = try ProjectReviewUITests.Fixture(); defer { other.clean() }
        let otherModel = AppModel(libraryURL: other.library, defaults: f.defaults)
        let application = WorkbenchApplicationLog(defaults: f.defaults)
        application.event("正在退出 RAWMaster")
        XCTAssertEqual(WorkbenchApplicationLog(defaults: f.defaults).entries, application.entries)
        XCTAssertTrue(WorkbenchApplicationLog(defaults: other.defaults).entries.isEmpty)
        let secret = "/private/project/prompt-with-an-access-key"
        model.progress = TaskProgress(title: "扫描素材", completed: 3, total: 9, message: secret)
        model.workbenchPhotoDelivery = WorkbenchPhotoDelivery(directory: f.root, assets: [], resumedCount: 4)
        model.errorMessage = "当前资料库操作失败"
        let running = WorkbenchActivityTask.live(model).filter(\.active)
        let fixtureNames: Set<String> = ["扫描素材", "导出成片"]
        XCTAssertTrue(fixtureNames.isSubset(of: Set(running.map(\.name))))
        XCTAssertTrue(fixtureNames.isDisjoint(with: WorkbenchActivityTask.live(otherModel).map(\.name)))
        XCTAssertEqual(model.activity.notices.last?.text, "当前资料库操作失败")
        XCTAssertTrue(otherModel.activity.notices.isEmpty)
        model.progress = TaskProgress(title: "扫描素材", completed: 9, total: 9, message: secret, isRunning: false)
        model.workbenchPhotoDelivery?.running = false
        XCTAssertTrue(fixtureNames.isDisjoint(with: WorkbenchActivityTask.live(model).filter(\.active).map(\.name)))
        XCTAssertTrue(model.activity.logs.contains { $0.message == "交付任务已结束" })
        XCTAssertFalse(model.activity.logs.contains { $0.message.contains(secret) })
        XCTAssertFalse(otherModel.activity.logs.contains { $0.source == "导出" })
        _ = try await f.populate("Direct export")
        let asset = try XCTUnwrap(f.store.loadAssets().first)
        let source = try f.store.captureEditingSourceSnapshot(assetID: asset.id)
        let work = try f.store.createPhotoWork(source: source)
        let receipt = try f.store.enqueueRenderedExport(commandID: UUID().uuidString, workID: work.id,
            versionID: work.originalVersionID, format: .jpeg8, targetURL: f.root.appending(path: "review.jpg"))
        let queued = try await WorkbenchActivityTask.catalog(f.library, store: f.store)
        XCTAssertTrue(queued.contains { $0.id == "render." + receipt.id && $0.active })
        _ = try f.store.cancelRenderedExport(id: receipt.id)
        let cancelled = try await WorkbenchActivityTask.catalog(f.library, store: f.store)
        XCTAssertTrue(cancelled.contains { $0.id == "render." + receipt.id && !$0.active && $0.status.contains("已取消") })
        await model.editing?.shutdown(finishPreviews: false)
        await otherModel.editing?.shutdown(finishPreviews: false)
    }

    @MainActor func testSimpleToastTimerIsScopedToReplacementAndPreservesHistory() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("Toast")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        let editing = try XCTUnwrap(model.editing), asset = try XCTUnwrap(f.store.loadAssets().first)
        editing.isPresented = true; editing.focus(asset)
        let window = NSWindow(contentRect: .init(x: 70, y: 100, width: 440, height: 110),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditingNoticeOverlay(editing: editing, returnFocus: {}))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        editing.postNotice("第一次提示")
        let first = try XCTUnwrap(editing.activeNotice)
        try await Task.sleep(for: .milliseconds(600))
        editing.postNotice("替换后发生了错误", kind: .error)
        let replacement = try XCTUnwrap(editing.activeNotice)
        XCTAssertNotEqual(first.id, replacement.id)
        try await Task.sleep(for: .milliseconds(3250))
        XCTAssertEqual(editing.activeNotice, replacement, "The first 3.5-second timer must not clear the 6-second error")
        for _ in 0..<45 where editing.activeNotice != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(editing.activeNotice)
        XCTAssertTrue(editing.photoNotices.contains(first) && editing.photoNotices.contains(replacement))
        await editing.shutdown(finishPreviews: false)
    }
}
