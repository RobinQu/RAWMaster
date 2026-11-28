import AppKit
import CSQLite
import CryptoKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

/// Opt-in rendering evidence at exact content bounds. The input database is
/// opened read-only for SQLite backup; all fixture changes use a disposable copy.
final class BrowserRefinementCaptureTests: XCTestCase {
    private struct Evidence: Codable {
        let filename: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
        let mode: String
        let selectedFiles: Int
        let sequenceSegments: Int
        let scrolledMetadata: Bool
        let scrollDocumentHeight: Double?
        let scrollViewportHeight: Double?
        let scrollOffset: Double?
    }

    @MainActor func testOptionalBrowserRefinementCaptures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["RAWMASTER_BROWSER_LAYOUT_LIBRARY"],
              let destination = environment["RAWMASTER_BROWSER_LAYOUT_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_BROWSER_LAYOUT_LIBRARY and RAWMASTER_BROWSER_LAYOUT_OUTPUT for 011 layout captures")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterBrowserCapture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let library = temporary.appendingPathComponent("capture.sqlite")
        try backup(source: source, destination: library)
        let suite = "RAWMasterBrowserCapture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        let store = try LibraryStore(databaseURL: library)
        let published = model.publishedAssets
        let project = try XCTUnwrap(model.projects.first { $0.name.hasPrefix("011") }
            ?? model.projects.first { $0.name.hasPrefix("009") }
            ?? model.projects.max { lhs, rhs in
                published.filter { $0.projectID == lhs.id }.count < published.filter { $0.projectID == rhs.id }.count
            })
        model.selectScope(.project, id: project.id)
        model.clearProjectSearch(); model.setMode(.grid)
        model.showSidebar = true; model.showInspector = true
        XCTAssertGreaterThanOrEqual(model.browserAssets.count, 2, "Capture fixture needs at least two published photo cards")
        guard model.browserAssets.count >= 2 else { return }

        if !model.groups.contains(where: { group in model.scopedAssets.contains { group.assetIDs.contains($0.id) } }) {
            let ids = Array(model.scopedAssets.prefix(6)).map(\.id)
            let preview = try store.previewGroupCommand(.create(assetIDs: ids, name: "山间日落 · 连拍序列", kind: "连拍"))
            _ = try store.commitGroupCommand(preview)
            model.reload()
        }
        let candidates = model.browserAssets
        for (index, asset) in candidates.prefix(4).enumerated() {
            model.setColorLabel([PhotoColorLabel.red, .green, .blue, .purple][index], assetIDs: [asset.id])
        }
        model.decideAsset(id: candidates[0].id, decision: .keep, rating: 4)
        model.decideAsset(id: candidates[1].id, rating: 3)
        var evidence: [Evidence] = []
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            model.setMode(.grid); model.selectedIDs = [candidates[0].id]; model.focusedID = candidates[0].id
            evidence.append(try await capture(model, output: output, dark: dark, name: "grid-wrapped-sequence-" + appearance))
            setComparison(model, candidates: Array(candidates.prefix(2)), mode: .rgb)
            evidence.append(try await capture(model, output: output, dark: dark, name: "compare-rgb2-" + appearance))
            if candidates.count >= 4 {
                setComparison(model, candidates: Array(candidates.prefix(4)), mode: .rgb)
                evidence.append(try await capture(model, output: output, dark: dark, name: "compare-rgb4-" + appearance))
            }
            setComparison(model, candidates: Array(candidates.prefix(4)), mode: .metadata)
            evidence.append(try await capture(model, output: output, dark: dark, name: "compare-metadata-initial-" + appearance))
            evidence.append(try await capture(model, output: output, dark: dark, name: "compare-metadata-scrolled-" + appearance, scrollMetadata: true))
            setComparison(model, candidates: Array(candidates.prefix(4)), mode: .histogram)
            evidence.append(try await capture(model, output: output, dark: dark, name: "compare-histogram-" + appearance))
            model.setMode(.single); model.selectedIDs = [candidates[0].id]; model.focusedID = candidates[0].id
            evidence.append(try await capture(model, output: output, dark: dark, name: "single-filmstrip-" + appearance))
            model.mode = .compare; model.selectedIDs = []; model.focusedID = nil
            evidence.append(try await capture(model, output: output, dark: dark, name: "compare-empty-" + appearance))
        }
        // Leave the exported native QA database on a populated project grid.
        model.setMode(.grid); model.selectedIDs = [candidates[0].id]; model.focusedID = candidates[0].id
        model.saveBrowse(); model.flushProjectReviewState()
        let native = output.appendingPathComponent("native-library.sqlite")
        try backup(source: library.path, destination: native)
        XCTAssertEqual(try LibraryStore(databaseURL: native).loadAssets().count, model.assets.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: output.appendingPathComponent("capture-dimensions.json"))
    }

    @MainActor private func setComparison(_ model: AppModel, candidates: [AssetRecord], mode: ComparisonMode) {
        model.setMode(.grid)
        model.selectedIDs = Set(candidates.map(\.id)); model.focusedID = candidates.last?.id
        model.setMode(.compare); model.comparisonMode = mode
    }

    private func backup(source: String, destination: URL) throws {
        func failure(_ operation: String, _ code: Int32, _ handle: OpaquePointer?) -> NSError {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite handle"
            return NSError(domain: "BrowserRefinementCapture.SQLite", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: operation + ": " + message])
        }
        let sourceURL = URL(fileURLWithPath: source)
        let walPath = source + "-wal"
        let headerFile = try FileHandle(forReadingFrom: sourceURL)
        let header = try headerFile.read(upToCount: 20) ?? Data()
        try headerFile.close()
        let standaloneWAL = !FileManager.default.fileExists(atPath: walPath)
            && header.count == 20 && header[18] == 2 && header[19] == 2
        func digest() throws -> SHA256.Digest {
            let file = try FileHandle(forReadingFrom: sourceURL)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize()
        }
        // Match the production migration-backup guard for standalone WAL-format
        // snapshots that system SQLite cannot ordinarily read in read-only mode.
        let originalHash = standaloneWAL ? try digest() : nil
        func verifyStandaloneSource() throws {
            if let originalHash {
                guard !FileManager.default.fileExists(atPath: walPath), try digest() == originalHash else {
                    throw NSError(domain: "BrowserRefinementCapture.SQLite", code: Int(SQLITE_BUSY),
                        userInfo: [NSLocalizedDescriptionKey: "Standalone QA source changed during backup; discard this capture and retry with a stable snapshot"])
                }
            }
        }
        let sourceName = standaloneWAL ? sourceURL.absoluteString + "?immutable=1" : source
        var input: OpaquePointer?
        let inputStatus = sqlite3_open_v2(sourceName, &input,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (standaloneWAL ? SQLITE_OPEN_URI : 0), nil)
        guard inputStatus == SQLITE_OK else {
            let error = failure("Open read-only QA source", inputStatus, input)
            sqlite3_close(input); throw error
        }
        defer { sqlite3_close(input) }
        sqlite3_busy_timeout(input, 5_000)
        try verifyStandaloneSource()
        var output: OpaquePointer?
        let outputStatus = sqlite3_open_v2(destination.path, &output,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard outputStatus == SQLITE_OK else {
            let error = failure("Open disposable QA destination", outputStatus, output)
            sqlite3_close(output); throw error
        }
        var complete = false
        defer {
            sqlite3_close(output)
            if !complete {
                for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: destination.path + suffix) }
            }
        }
        sqlite3_busy_timeout(output, 5_000)
        guard let transfer = sqlite3_backup_init(output, "main", input, "main") else {
            throw failure("Initialize consistent QA backup", sqlite3_errcode(output), output)
        }
        var status = sqlite3_backup_step(transfer, -1)
        var attempts = 0
        while (status == SQLITE_BUSY || status == SQLITE_LOCKED), attempts < 20 {
            sqlite3_sleep(100); attempts += 1
            status = sqlite3_backup_step(transfer, -1)
        }
        let finish = sqlite3_backup_finish(transfer)
        guard status == SQLITE_DONE, finish == SQLITE_OK else {
            throw failure("Copy QA snapshot (step \(status), finish \(finish))", status, input)
        }
        // Produce a self-contained file for the later native QA app; the source
        // is never checkpointed or opened writable, including when it has a WAL.
        let journal = sqlite3_exec(output, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", nil, nil, nil)
        guard journal == SQLITE_OK else { throw failure("Finalize QA snapshot", journal, output) }
        try verifyStandaloneSource()
        complete = true
    }

    @MainActor private func capture(_ model: AppModel, output: URL, dark: Bool, name: String, scrollMetadata: Bool = false) async throws -> Evidence {
        let size = NSSize(width: 1100, height: 720)
        let content = WorkbenchView().environmentObject(model)
            .preferredColorScheme(dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        host.layoutSubtreeIfNeeded()
        var documentHeight: Double?, viewportHeight: Double?, offset: Double?
        if scrollMetadata {
            XCTAssertEqual(model.comparisonMode, .metadata)
            let table = try XCTUnwrap(scrollViews(in: host).filter { scroll in
                guard let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.height > 80 && scroll.contentView.bounds.width > 300
                    && document.bounds.height > scroll.contentView.bounds.height + 40
            }.max { lhs, rhs in
                (lhs.documentView?.bounds.height ?? 0) - lhs.contentView.bounds.height
                    < (rhs.documentView?.bounds.height ?? 0) - rhs.contentView.bounds.height
            }, "Expected the metadata table's vertical scroller, without changing the horizontal filmstrip")
            let document = try XCTUnwrap(table.documentView)
            documentHeight = document.bounds.height; viewportHeight = table.contentView.bounds.height
            let target = min(260, max(0, document.bounds.height - table.contentView.bounds.height))
            table.contentView.scroll(to: NSPoint(x: table.contentView.bounds.minX, y: target))
            table.reflectScrolledClipView(table.contentView)
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            offset = table.contentView.bounds.minY
            XCTAssertGreaterThan(try XCTUnwrap(offset), 30, "Metadata must actually scroll for pinned-header evidence")
        }
        XCTAssertEqual(host.bounds.width, size.width, accuracy: 0.01)
        XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.01)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(Double(bitmap.pixelsWide) / size.width, Double(bitmap.pixelsHigh) / size.height, accuracy: 0.001)
        let filename = name + ".png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
        return Evidence(filename: filename, logicalWidth: host.bounds.width, logicalHeight: host.bounds.height,
            pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, appearance: dark ? "dark" : "light",
            mode: model.mode == .compare ? model.comparisonMode.rawValue : model.mode.rawValue,
            selectedFiles: model.selectedIDs.count, sequenceSegments: model.sequenceBrowserLayout.segments.filter { $0.group != nil }.count,
            scrolledMetadata: scrollMetadata, scrollDocumentHeight: documentHeight, scrollViewportHeight: viewportHeight, scrollOffset: offset)
    }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
