import AppKit
import Darwin
import SwiftUI
import XCTest
import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary
@testable import RAWMaster

final class LibraryGridPerformanceTests: XCTestCase {
    struct Row: Codable {
        let workload: String
        let action: String
        let event: UInt64
        let nativeDraw: UInt64
        let cells: Int
        let photos: Int
        let rssBytes: Int64
        var milliseconds: Double { Double(nativeDraw - event) / 1_000_000 }
    }

    @MainActor final class Recorder {
        var rows = [CatalogGridPaintRecorder.Sample]()
        func first(after start: UInt64, in window: NSWindow, model: AppModel, photo: Bool = false) async throws -> CatalogGridPaintRecorder.Sample {
            let end = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
            while DispatchTime.now().uptimeNanoseconds < end {
                while let event = NSApp.nextEvent(matching:.any, until:.distantPast, inMode:.default, dequeue:true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if let error = model.catalogGrid?.errorDescription ?? model.errorMessage, model.catalogGrid?.cards.isEmpty != false {
                    throw LibraryEngineError("网格读取失败：" + error)
                }
                if let value = rows.first(where: { $0.startNanoseconds >= start && (photo ? $0.cardsWithPhotoDrawn > 0 : ($0.visibleCardsDrawn > 0 || $0.empty)) }) {
                    return value
                }
                try await Task.sleep(for: .milliseconds(4))
            }
            func markers(_ view: NSView) -> [NSView] { (view is CatalogGridPaintMark.Marker ? [view] : []) + view.subviews.flatMap(markers) }
            let marks = window.contentView.map(markers) ?? []
            let details = "窗口显示 \(window.isVisible)，可见 \(window.occlusionState.contains(.visible))，卡片 \(model.catalogGrid?.cards.count ?? 0)，最近事件 \(rows.last?.startNanoseconds ?? 0)/\(start)，绘制视图 \(marks.count)，首个视图 \(marks.first?.frame.debugDescription ?? "未知")"
            FileHandle.standardError.write(Data(("未收到网格绘制： " + details + "\n").utf8))
            throw LibraryEngineError(details)
        }
    }

    static func rss() -> Int64 {
        var counters = rusage()
        getrusage(RUSAGE_SELF, &counters)
        return Int64(counters.ru_maxrss)
    }

    @MainActor func testExistingCatalogFirstPaintDuringRawImport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["RAWMASTER_LIBRARY_UI_REPORT"], let fixture = environment["RM_CATALOG_BACKUP"],
              let rawInput = environment["RAWMASTER_RUNTIME_RAW_DIRECTORY"], let tool = environment["RAWMASTER_RUNTIME_TOOL_ROOT"] else {
            throw XCTSkip("选择既有资料库的一致快照、实拍 RAW、元数据组件和独立输出路径后运行发布测试")
        }
        #if DEBUG
        throw XCTSkip("首屏基线使用 release 配置")
        #else
        let original = URL(fileURLWithPath: fixture)
        let raw = URL(fileURLWithPath: rawInput, isDirectory: true)
        let toolRoot = URL(fileURLWithPath: tool)
        let fm = FileManager.default
        let sourceWAL = (try? fm.attributesOfItem(atPath:original.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(sourceWAL, 0)
        guard sourceWAL == 0 else { throw LibraryEngineError("请选择已完成检查点的基准目录副本") }
        let root = fm.temporaryDirectory.appendingPathComponent("rawmaster-library-screen-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        var all = [Row]()
        var indexSizes: [Int64] = []
        var imports: [Int] = []
        var startup = [[String:Double]]()
        var reopenPhases = [[String:Double]]()
        for trial in 0..<4 {
            let folder = root.appendingPathComponent("Trial" + String(trial), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let database = folder.appendingPathComponent("library.sqlite")
            try fm.copyItem(at: original, to: database)
            let domain = "RAWMaster.Library.UI." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let recorder = Recorder()
            let openStart = DispatchTime.now().uptimeNanoseconds
            let model = AppModel(libraryURL: database, defaults: defaults, usesPagedLibrary: true,
                                 catalogPaint: { recorder.rows.append($0) })
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                               styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            win.contentView = NSHostingView(rootView: WorkbenchView().environmentObject(model))
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            win.level = .floating
            if let screen = NSScreen.screens.first {
                let area = screen.visibleFrame
                win.setFrameOrigin(NSPoint(x:area.midX - win.frame.width / 2,y:area.midY - win.frame.height / 2))
            }
            app.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            defer { win.orderOut(nil); win.close() }
            func measured(_ workload: String, _ action: String, _ start: UInt64) async throws -> Row {
                let visible = try await recorder.first(after: start, in: win, model: model)
                return Row(workload: workload, action: action, event: start, nativeDraw: visible.drawNanoseconds,
                           cells: visible.visibleCardsDrawn, photos: visible.cardsWithPhotoDrawn, rssBytes: Self.rss())
            }
            all.append(try await measured("open", "existing-v7", openStart))
            startup.append(model.catalogStartupPhases)
            let firstPhoto = try await recorder.first(after:openStart,in:win,model:model,photo:true)
            all.append(Row(workload:"openPhoto",action:"existing-v7",event:openStart,nativeDraw:firstPhoto.drawNanoseconds,
                           cells:firstPhoto.visibleCardsDrawn,photos:firstPhoto.cardsWithPhotoDrawn,rssBytes:Self.rss()))
            func query(_ sample: Int, _ workload: String) async throws -> Row {
                let variants: [(String,ProjectSearchQuery)] = [("all",.init()),("rating>=4",.init(minimumRating: 4))]
                let (label,q) = variants[sample % variants.count]
                let event = DispatchTime.now().uptimeNanoseconds
                XCTAssertTrue(model.applyProjectSearch(q, sort: .capturedDescending, searchAllProjects: true))
                return try await measured(workload, label, event)
            }
            for number in 0..<6 {
                let row = try await query(number, "idle")
                all.append(row)
                if row.cells > 0 {
                    let image = try await recorder.first(after:row.event,in:win,model:model,photo:true)
                    all.append(Row(workload:"idlePhoto",action:row.action,event:row.event,nativeDraw:image.drawNanoseconds,
                                   cells:image.visibleCardsDrawn,photos:image.cardsWithPhotoDrawn,rssBytes:Self.rss()))
                }
            }

            let store = try LibraryStore(databaseURL: database)
            let importer = ImportService(store: store, postIngest: RuntimeAutomaticGroupingCoordinator.callback(
                store: store, libraryURL: database, toolRoot: toolRoot))
            let started = DispatchTime.now().uptimeNanoseconds
            let importTask = Task.detached {
                let session = try await importer.importDirectory(source: raw, destination: nil, projectName: "资料库实拍回归",
                    mode: .reference, initialScreening: true, progress: { _ in })
                return (try store.loadAssets(sessionID: session.id).count, DispatchTime.now().uptimeNanoseconds)
            }
            var probes = [Row]()
            for number in 0..<20 {
                let row = try await query(number, "import")
                probes.append(row)
                if row.cells > 0 {
                    let image = try await recorder.first(after:row.event,in:win,model:model,photo:true)
                    probes.append(Row(workload:"importPhoto",action:row.action,event:row.event,nativeDraw:image.drawNanoseconds,
                                      cells:image.visibleCardsDrawn,photos:image.cardsWithPhotoDrawn,rssBytes:Self.rss()))
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            let (count, finished) = try await importTask.value
            XCTAssertEqual(count, 6)
            let overlap = probes.filter { $0.event >= started && $0.nativeDraw <= finished }
            XCTAssertFalse(overlap.isEmpty)
            all.append(contentsOf: overlap)
            imports.append(count)
            let cache = "." + database.lastPathComponent + ".search.sqlite"
            let bytes = ["","-wal","-shm"].reduce(Int64(0)) { total, suffix in
                let attr = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(cache + suffix).path)
                return total + ((attr?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            indexSizes.append(bytes)
            let reopenRecorder = Recorder()
            let reopenStart = DispatchTime.now().uptimeNanoseconds
            let reopened = AppModel(libraryURL:database,defaults:defaults,usesPagedLibrary:true,catalogPaint:{ reopenRecorder.rows.append($0) })
            win.contentView = NSHostingView(rootView: WorkbenchView().environmentObject(reopened))
            win.orderFrontRegardless()
            let reopenedDraw = try await reopenRecorder.first(after:reopenStart,in:win,model:reopened)
            reopenPhases.append(reopened.catalogStartupPhases)
            let reopenedPhoto = try await reopenRecorder.first(after:reopenStart,in:win,model:reopened,photo:true)
            all.append(Row(workload:"reopenPhoto",action:"v8-index-present",event:reopenStart,nativeDraw:reopenedPhoto.drawNanoseconds,
                           cells:reopenedPhoto.visibleCardsDrawn,photos:reopenedPhoto.cardsWithPhotoDrawn,rssBytes:Self.rss()))
            all.append(Row(workload:"reopen",action:"v8-index-present",event:reopenStart,nativeDraw:reopenedDraw.drawNanoseconds,
                           cells:reopenedDraw.visibleCardsDrawn,photos:reopenedDraw.cardsWithPhotoDrawn,rssBytes:Self.rss()))
        }
        let metrics = Dictionary(grouping: all, by: \.workload).mapValues { rows -> [String:Double] in
            let ms = rows.map(\.milliseconds).sorted()
            func percentile(_ p: Double) -> Double { ms[Int(ceil(Double(ms.count) * p)) - 1] }
            return ["n": Double(ms.count), "p50ms": percentile(0.50), "p95ms": percentile(0.95), "maxMs": ms.last!]
        }
        let data = try JSONEncoder().encode(all)
        let document: [String:Any] = ["boundary":"input to visible AppKit grid draw", "build":"release",
            "trials":imports, "startupPhasesMs":startup, "reopenPhasesMs":reopenPhases, "distributions":metrics, "indexBytesIncludingWAL":indexSizes,
            "peakProcessRSSBytes":Self.rss(), "samples":try JSONSerialization.jsonObject(with: data)]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        // Guard the prior quadratic RAW/JPEG join on this 6,928-file catalog.
        for phases in startup + reopenPhases {
            XCTAssertLessThan(try XCTUnwrap(phases["navigationLoadMs"]), 2_000)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["idle"]?["p95ms"]), 300)
        XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["import"]?["p95ms"]), 300)
        XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["idlePhoto"]?["p95ms"]), 300)
        XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["importPhoto"]?["p95ms"]), 300)
        #endif
    }
}
