import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

/// Opt-in content-layout evidence. This does not establish WindowServer input or
/// title-bar acceptance; the shipping WorkbenchView is rendered at exact bounds.
final class WorkbenchLayoutCaptureTests: XCTestCase {
    private struct CaptureEvidence: Codable {
        let filename: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
        let mode: String
        let selectedFiles: Int
        let conditions: Int
        let searchExpanded: Bool
    }

    @MainActor func testOptionalExactWorkbenchLayoutCaptures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["RAWMASTER_LAYOUT_LIBRARY"],
              let destination = environment["RAWMASTER_LAYOUT_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_LAYOUT_LIBRARY and RAWMASTER_LAYOUT_OUTPUT to capture exact 1100×720 layout evidence")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterLayout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let library = temporary.appendingPathComponent("layout.sqlite")
        try backup(source: source, destination: library)
        let suite = "RAWMasterLayout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        let project = try XCTUnwrap(model.projects.first { $0.name.hasPrefix("009") } ?? model.projects.first)
        model.selectScope(.project, id: project.id)
        model.showSidebar = true; model.showInspector = true
        model.clearProjectSearch(); model.setMode(.grid)
        let candidates = model.browserAssets
        XCTAssertGreaterThanOrEqual(candidates.count, 2, "Layout fixture must include at least two published photos")
        guard candidates.count >= 2 else { return }
        let dates = candidates.compactMap(\.capturedAt)
        let start = dates.min() ?? Date(timeIntervalSince1970: 0)
        let end = dates.max() ?? Date()
        XCTAssertTrue(model.editSearchQuery { query in
            try query.setDateRange(startDay: start, endDay: end, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        })
        let matching = model.browserAssets
        XCTAssertGreaterThanOrEqual(matching.count, 2, "Date range must preserve at least two QA photos")
        guard matching.count >= 2 else { return }
        model.select(matching[0]); model.select(matching[1], modifiers: .command)
        model.focusProjectSearch()
        var evidence: [CaptureEvidence] = []
        for dark in [false, true] {
            evidence.append(try await capture(model, output: output, dark: dark, name: "grid-search-dates-" + (dark ? "dark" : "light")))
        }
        model.setMode(.compare)
        for mode in [ComparisonMode.metadata, .histogram] {
            model.comparisonMode = mode
            for dark in [false, true] {
                evidence.append(try await capture(model, output: output, dark: dark, name: "compare-" + mode.rawValue + "-" + (dark ? "dark" : "light")))
            }
        }
        model.flushProjectReviewState()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: output.appendingPathComponent("capture-dimensions.json"))
    }

    private func backup(source: String, destination: URL) throws {
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", source, ".backup '" + destination.path.replacingOccurrences(of: "'", with: "''") + "'"]
        process.standardError = errors
        try process.run(); process.waitUntilExit()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "Unable to make disposable QA database backup: " + message)
        guard process.terminationStatus == 0 else { throw NSError(domain: "WorkbenchLayout", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor private func capture(_ model: AppModel, output: URL, dark: Bool, name: String) async throws -> CaptureEvidence {
        let size = NSSize(width: 1100, height: 720)
        let content = WorkbenchView().environmentObject(model)
            .preferredColorScheme(dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        // Allow async thumbnail/metadata/histogram tasks to settle in the real view.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, size.width, accuracy: 0.01)
        XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.01)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scaleX = Double(bitmap.pixelsWide) / size.width
        let scaleY = Double(bitmap.pixelsHigh) / size.height
        XCTAssertEqual(scaleX, scaleY, accuracy: 0.001, "Bitmap backing scale must preserve logical bounds")
        XCTAssertGreaterThanOrEqual(scaleX, 1)
        let filename = name + ".png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
        return CaptureEvidence(filename: filename, logicalWidth: host.bounds.width, logicalHeight: host.bounds.height,
            pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, appearance: dark ? "dark" : "light",
            mode: model.mode == .compare ? model.comparisonMode.rawValue : model.mode.rawValue,
            selectedFiles: model.selectedIDs.count, conditions: model.searchConditionChips.count,
            searchExpanded: model.showSearchFilters)
    }
}
