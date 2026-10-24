import AppKit
import Combine
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster
@testable import RAWMasterImaging

/// Explicit release benchmark of hit-tested shipping native card receivers and SwiftUI updates.
/// A real NSWindow hosts the grid / filmstrip, but XCTest dispatches directly to the receiver:
/// this excludes OS delivery and WindowServer presentation. No global input is posted.
final class UIClickPerformanceTests: XCTestCase {
    enum Surface: String, CaseIterable { case grid, filmstrip }
    struct Sample: Encodable {
        let surface: String
        let ordinal: Int
        let targetOrdinal: Int
        let eventUptimeSeconds: Double
        let selectionUptimeSeconds: Double
        let viewUpdateUptimeSeconds: Double
        let relocation: RelocationSampleEvidence?
        var eventToSelectionMs: Double { (selectionUptimeSeconds - eventUptimeSeconds) * 1000 }
        var eventToViewUpdateMs: Double { (viewUpdateUptimeSeconds - eventUptimeSeconds) * 1000 }
        enum CodingKeys: String, CodingKey { case surface, ordinal, targetOrdinal, eventUptimeSeconds, selectionUptimeSeconds, viewUpdateUptimeSeconds, eventToSelectionMs, eventToViewUpdateMs, relocation }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(surface, forKey: .surface); try c.encode(ordinal, forKey: .ordinal); try c.encode(targetOrdinal, forKey: .targetOrdinal)
            try c.encode(eventUptimeSeconds, forKey: .eventUptimeSeconds); try c.encode(selectionUptimeSeconds, forKey: .selectionUptimeSeconds)
            try c.encode(viewUpdateUptimeSeconds, forKey: .viewUpdateUptimeSeconds)
            try c.encode(eventToSelectionMs, forKey: .eventToSelectionMs); try c.encode(eventToViewUpdateMs, forKey: .eventToViewUpdateMs)
            try c.encodeIfPresent(relocation, forKey: .relocation)
        }
    }
    struct Distribution: Encodable {
        let count: Int; let p50Ms: Double; let p95Ms: Double; let maxMs: Double
        init(_ values: [Double]) {
            let sorted = values.sorted(); count = sorted.count
            func percentile(_ p: Double) -> Double { sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))] }
            p50Ms = percentile(0.50); p95Ms = percentile(0.95); maxMs = sorted.last ?? 0
        }
    }
    struct SurfaceReport: Encodable {
        let surface: String; let eventToSelection: Distribution; let eventToViewUpdate: Distribution
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let boundary = "Constructed NSEvent.timestamp → native hit-test / receiver → changed focusedID publication / NSViewRepresentable update; not WindowServer presentation"
        let dispatch = "hit-tested shipping CardInputView.mouseDown in mounted BrowserView / FilmstripView; NSApplication is inactive in XCTest; not WindowServer event delivery"
        let mode: String
        let build: String
        let operatingSystem: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
        let doubleClickIntervalMs: Double
        let assetCount: Int
        let fixture: String
        let thumbnailState = "500ms host settling before timed loop; decoding not included in selection completion"
        let selectionP95BudgetMs: Double
        let viewP95BudgetMs: Double
        let selectionMaxBudgetMs: Double
        let viewMaxBudgetMs: Double
        let surfaces: [SurfaceReport]
        let samples: [Sample]
        let failures: [String]
        let relocationWorkload: RelocationWorkloadReport?
    }

    @MainActor final class Recorder {
        struct Pending { let target: String; let ordinal: Int; let targetOrdinal: Int; let start: Double; var selection: Double?; var view: Double? }
        var pending: Pending?
        func focus(_ id: String?) {
            guard var p = pending, id == p.target, p.selection == nil else { return }
            p.selection = ProcessInfo.processInfo.systemUptime; pending = p
        }
        func updated(_ id: String?) {
            guard var p = pending, id == p.target, p.selection != nil, p.view == nil else { return }
            p.view = ProcessInfo.processInfo.systemUptime; pending = p
        }
    }
    struct UpdateProbe: NSViewRepresentable {
        let assetID: String?; let callback: (String?) -> Void
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
        func updateNSView(_ nsView: NSView, context: Context) { callback(assetID) }
    }
    final class EventHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    struct Host: View {
        @ObservedObject var model: AppModel
        let surface: Surface
        let recorder: Recorder
        var body: some View {
            Group {
                if surface == .grid { BrowserView() }
                else { VStack(spacing: 0) { FilmstripView(); Spacer(minLength: 0) } }
            }
            .environmentObject(model).preferredColorScheme(.dark)
            .background(UpdateProbe(assetID: model.focusedID) { recorder.updated($0) })
        }
    }

    @MainActor func testReleaseShippingCardInputLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["RAWMASTER_UI_PERF_REPORT"] else { throw XCTSkip("Opt in with RAWMASTER_UI_PERF_REPORT and swift test -c release --filter UIClickPerformanceTests") }
        try requireReleaseConfiguration()
        let count = max(30, Int(environment["RAWMASTER_UI_PERF_SAMPLES"] ?? "30") ?? 30)
        let gated = environment["RAWMASTER_UI_PERF_GATE"] == "1"
        let selectionBudget = Double(environment["RAWMASTER_UI_SELECTION_P95_MS"] ?? "100") ?? 100
        let viewBudget = Double(environment["RAWMASTER_UI_VIEW_P95_MS"] ?? "150") ?? 150
        let selectionMax = 150.0, viewMax = 250.0
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let externalLibrary = environment["RAWMASTER_UI_PERF_LIBRARY"].map { URL(fileURLWithPath: $0) }
        let withRelocation = environment["RAWMASTER_UI_PERF_RELOCATION"] == "1"
        guard !withRelocation || externalLibrary == nil else { throw RelocationWorkloadError.externalLibraryForbidden }
        var tinySession: ImportSession?
        if externalLibrary == nil { tinySession = try await fixture.populate(count: 152) }
        let payload = withRelocation ? try await prepareRelocationPayload(fixture) : nil
        let model = AppModel(libraryURL: externalLibrary ?? fixture.library, defaults: fixture.defaults)
        guard model.assets.count >= 2 else { XCTFail("Benchmark needs at least two registered assets: \(model.errorMessage ?? "empty library")"); return }
        if withRelocation, let tinySession { model.selectScope(.session, id: tinySession.id) }
        else { model.selectScope(.all) }
        model.filter = .all; model.setMode(.grid)
        // Explicitly capture the two visible tiny-image IDs; the synthetic asset is in another session.
        let targetIDs = Array(model.filteredAssets.prefix(2)).map(\.id)
        let snapshotEncoder = JSONEncoder(); snapshotEncoder.outputFormatting = .sortedKeys
        let businessBefore = try snapshotEncoder.encode(fixture.store.loadAssets())
        let groupsBefore = try snapshotEncoder.encode(fixture.store.loadGroups())
        let workload = payload.map { RelocationWorkload(model: model, payload: $0) }
        defer { workload?.requestStop() }
        workload?.start()
        if let workload { try await workload.waitForActiveScan() }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        var samples: [Sample] = [], failures: [String] = []
        let benchmarkDeadline = ProcessInfo.processInfo.systemUptime + 180
        for surface in Surface.allCases {
            let recorder = Recorder()
            let host = EventHostingView(rootView: Host(model: model, surface: surface, recorder: recorder).frame(width: 780, height: 500))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "RAWMaster in-process \(surface.rawValue) benchmark"
            window.isReleasedWhenClosed = false; window.contentView = host
            window.center(); window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 500_000_000)
            print("UI benchmark host", surface.rawValue, "bounds", host.bounds, "active", application.isActive, "key", window.isKeyWindow, "flipped", host.isFlipped)
            let observation = model.$focusedID.sink { recorder.focus($0) }
            for ordinal in 0..<count {
                if failures.count >= 3 { break }
                if ProcessInfo.processInfo.systemUptime > benchmarkDeadline { failures.append("Benchmark exceeded 180 seconds"); break }
                if let workload { try await workload.waitForActiveScan() }
                let targetOrdinal = ordinal % 2 == 0 ? 1 : 0
                let target = try XCTUnwrap(model.assets.first { $0.id == targetIDs[targetOrdinal] })
                guard model.focusedID != target.id else { failures.append("\(surface.rawValue)[\(ordinal)] target was already focused; changed-selection sample invalid"); continue }
                // Fixed viewport keeps the first two shipping cards visible without scrolling.
                let pointFromTop = surface == .grid ? CGPoint(x: targetOrdinal == 0 ? 137 : 390, y: 88) : CGPoint(x: targetOrdinal == 0 ? 65 : 175, y: 42)
                let local = host.isFlipped ? pointFromTop : CGPoint(x: pointFromTop.x, y: host.bounds.height - pointFromTop.y)
                let point = host.convert(local, to: nil)
                let backgroundAtEvent = workload?.sampleEvidence()
                let start = ProcessInfo.processInfo.systemUptime
                recorder.pending = Recorder.Pending(target: target.id, ordinal: ordinal, targetOrdinal: targetOrdinal, start: start)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: start, windowNumber: window.windowNumber, context: nil, eventNumber: ordinal * 2 + 1, clickCount: 1, pressure: 1))
                let hitPoint = host.convert(local, to: host.superview)
                let receiver = host.hitTest(hitPoint)
                guard let receiver = receiver as? CardInputView else { failures.append("\(surface.rawValue)[\(ordinal)] shipping card input was not hit: \(String(describing: receiver))"); break }
                receiver.mouseDown(with: down)
                try await Task.sleep(nanoseconds: 10_000_000)
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: ordinal * 2 + 2, clickCount: 1, pressure: 0))
                receiver.mouseUp(with: up)
                let deadline = start + max(2, NSEvent.doubleClickInterval * 3)
                while recorder.pending?.view == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                guard let p = recorder.pending, let selected = p.selection, let updated = p.view else {
                    failures.append("\(surface.rawValue)[\(ordinal)] event did not produce target selection and NSView update before timeout; focusedOrdinal=\(model.assets.firstIndex { $0.id == model.focusedID } ?? -1), point=\(point), hit=\(String(describing: host.hitTest(hitPoint)))")
                    recorder.pending = nil; continue
                }
                samples.append(Sample(surface: surface.rawValue, ordinal: ordinal, targetOrdinal: targetOrdinal, eventUptimeSeconds: start, selectionUptimeSeconds: selected, viewUpdateUptimeSeconds: updated, relocation: backgroundAtEvent.map { RelocationSampleEvidence(jobRunningAtEvent: $0.jobRunningAtEvent, scannedEntriesAtEvent: $0.scannedEntriesAtEvent, scanCycleAtEvent: $0.scanCycleAtEvent, jobRunningWhenCollected: model.relocationIsRunning, scannedEntriesWhenCollected: workload?.totalScannedEntries ?? 0) }))
                recorder.pending = nil
                // Settle the previous view update before starting another explicit single-click sample.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            withExtendedLifetime(observation) {}
            window.orderOut(nil); window.close()
        }
        if let workload { await workload.stop() }
        let photoRecordsUnchanged = try snapshotEncoder.encode(fixture.store.loadAssets()) == businessBefore
        let groupRecordsUnchanged = try snapshotEncoder.encode(fixture.store.loadGroups()) == groupsBefore
        let workloadReport = workload.map { $0.report(samples: samples, photoRecordsUnchanged: photoRecordsUnchanged, groupRecordsUnchanged: groupRecordsUnchanged) }
        if let workloadReport {
            if !photoRecordsUnchanged { failures.append("Read-only relocation changed photo fields") }
            if !groupRecordsUnchanged { failures.append("Read-only relocation changed group membership or participation") }
            if !workloadReport.failures.isEmpty { failures.append(contentsOf: workloadReport.failures) }
            if workloadReport.progressEntriesWithinMeasurement <= 0 { failures.append("No real relocation scan progress overlapped the measured clicks") }
            if workloadReport.samplesWithActiveJobAtEvent < Int(ceil(Double(samples.count) * 0.9)) { failures.append("Relocation was active at fewer than 90% of measured input samples") }
            if workloadReport.persistedFullHashCandidateEvidenceCount <= 0 { failures.append("No persisted full-SHA256 candidate evidence proves the background scan hashed the fixture") }
            if !workloadReport.cancelledAndJoined { failures.append("Background relocation did not cancel and join before cleanup") }
            if workloadReport.serviceActiveFractionDuringMeasurement < 0.9 { failures.append("Relocation service-active interval coverage was below 90%") }
            for surface in Surface.allCases {
                let matching = samples.filter { $0.surface == surface.rawValue }
                if matching.filter({ $0.relocation?.jobRunningAtEvent == true }).count < Int(ceil(Double(count) * 0.9)) { failures.append("\(surface.rawValue) did not have at least 90% active relocation samples") }
                if let first = matching.map(\.eventUptimeSeconds).min(), let last = matching.map(\.viewUpdateUptimeSeconds).max(),
                   !workloadReport.progress.contains(where: { $0.uptimeSeconds >= first && $0.uptimeSeconds <= last }) { failures.append("\(surface.rawValue) has no actual scan progress during its measured window") }
            }
        }
        let summaries = Surface.allCases.compactMap { surface -> SurfaceReport? in
            let matching = samples.filter { $0.surface == surface.rawValue }
            guard !matching.isEmpty else { return nil }
            return SurfaceReport(surface: surface.rawValue, eventToSelection: Distribution(matching.map(\.eventToSelectionMs)), eventToViewUpdate: Distribution(matching.map(\.eventToViewUpdateMs)))
        }
        let report = Report(mode: gated ? "budget-gated" : "baseline-measure-only", build: "release", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, processorCount: ProcessInfo.processInfo.processorCount, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, doubleClickIntervalMs: NSEvent.doubleClickInterval * 1000, assetCount: model.assets.count, fixture: withRelocation ? "152 generated tiny images plus one 256MiB synthetic relocation asset in an isolated session; synthetic read/hash IO, not RAW decoding or real source media" : externalLibrary == nil ? "152 generated tiny image fixtures" : "explicit isolated opt-in library; path omitted", selectionP95BudgetMs: selectionBudget, viewP95BudgetMs: viewBudget, selectionMaxBudgetMs: selectionMax, viewMaxBudgetMs: viewMax, surfaces: summaries, samples: samples, failures: failures, relocationWorkload: workloadReport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: destination, options: .atomic)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        for summary in summaries {
            XCTAssertEqual(summary.eventToSelection.count, count, "All required changed-selection samples must complete")
            if gated {
                XCTAssertLessThanOrEqual(summary.eventToSelection.p95Ms, selectionBudget, "\(summary.surface) selection p95 exceeded budget")
                XCTAssertLessThanOrEqual(summary.eventToViewUpdate.p95Ms, viewBudget, "\(summary.surface) view-update p95 exceeded budget")
                XCTAssertLessThanOrEqual(summary.eventToSelection.maxMs, selectionMax, "\(summary.surface) selection max exceeded budget")
                XCTAssertLessThanOrEqual(summary.eventToViewUpdate.maxMs, viewMax, "\(summary.surface) view-update max exceeded budget")
            }
        }
        XCTAssertEqual(summaries.count, Surface.allCases.count)
    }
}

extension UIClickPerformanceTests {
    enum BenchmarkConfigurationError: Error { case releaseConfigurationRequired }
    private func requireReleaseConfiguration() throws {
        #if DEBUG
        throw BenchmarkConfigurationError.releaseConfigurationRequired
        #endif
    }
    @MainActor private func mouseEvent(_ type: NSEvent.EventType = .leftMouseDown, count: Int = 1, modifiers: NSEvent.ModifierFlags = [], point: CGPoint = CGPoint(x: 20, y: 20)) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
    }

    @MainActor func testNativeSelectionCallbackCompletesOnMouseDownCallStack() throws {
        let view = CardInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        var returnedFromDispatch = false, selected = false
        view.onPress = { flags in
            XCTAssertFalse(returnedFromDispatch)
            XCTAssertEqual(flags, [.command, .shift])
            selected = true
        }
        view.mouseDown(with: try mouseEvent(modifiers: [.command, .shift]))
        returnedFromDispatch = true
        XCTAssertTrue(selected, "Selection must occur before mouseDown returns, without a double-click timer")
    }

    @MainActor func testNativeDoubleClickAndModifierSelectionUseShippingModel() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 5)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let shots = model.assets
        let view = CardInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.onPress = { model.select(shots[3], modifiers: $0) }
        view.onDoubleClick = { model.select(shots[3]); model.setMode(.single) }
        model.select(shots[0])
        view.mouseDown(with: try mouseEvent(modifiers: .command))
        XCTAssertEqual(model.selectedIDs, [shots[0].id, shots[3].id])
        model.select(shots[0])
        view.mouseDown(with: try mouseEvent(modifiers: .shift))
        XCTAssertEqual(model.selectedAssets.map(\.id), Array(shots[0...3]).map(\.id))
        view.mouseDown(with: try mouseEvent(count: 2))
        XCTAssertEqual(model.selectedIDs, [shots[3].id]); XCTAssertEqual(model.focusedID, shots[3].id)
        XCTAssertEqual(model.mode, .single)
    }

    @MainActor func testContextMenuAndScrollEventsPassThroughCardInput() throws {
        let view = CardInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        var selections = 0
        view.onPress = { _ in selections += 1 }
        let normal = try mouseEvent()
        view.currentEvent = { normal }
        XCTAssertTrue(view.hitTest(CGPoint(x: 20, y: 20)) === view)
        XCTAssertTrue(view.acceptsFirstMouse(for: normal))
        for event in [try mouseEvent(.rightMouseDown), try mouseEvent(modifiers: .control)] {
            view.currentEvent = { event }
            XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)), "Context menus must reach the original SwiftUI card")
            view.mouseDown(with: event)
        }
        let cgWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: cgWheel))
        view.currentEvent = { wheel }
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)), "Scrolling must reach the containing scroll view")
        XCTAssertEqual(selections, 0)
    }

    @MainActor func testManualCardSelectionPreservesViewportWhileKeyboardRevealsTarget() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 90)
        _ = NSApplication.shared
        for surface in Surface.allCases {
            let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
            model.selectScope(.all); model.setMode(.grid)
            let recorder = Recorder()
            let host = EventHostingView(rootView: Host(model: model, surface: surface, recorder: recorder).frame(width: 780, height: 500))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            let candidates = descendants(host).compactMap { $0 as? CardInputView }.filter {
                let frame = $0.convert($0.bounds, to: host)
                return frame.midX > 20 && frame.midX < host.bounds.maxX - 20 && frame.midY > 30 && frame.midY < min(450, host.bounds.maxY - 30)
            }
            let target = try XCTUnwrap(candidates.last)
            let origin = scroll.contentView.bounds.origin
            let reveal = model.navigationReveal
            target.mouseDown(with: try mouseEvent())
            try await Task.sleep(nanoseconds: 220_000_000)
            XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 0.5, "Manual \(surface.rawValue) click must not recenter")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5, "Manual \(surface.rawValue) click must not recenter")
            XCTAssertEqual(model.navigationReveal, reveal, "Manual selection must not request keyboard-style viewport movement")
            model.select(try XCTUnwrap(model.assets.last))
            model.move(-1)
            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertEqual(model.navigationReveal?.assetID, model.focusedID)
            if surface == .grid { XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, origin.y) }
            else { XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, origin.x) }
            window.close()
        }
    }

    @MainActor func testOrdinaryGridSelectionDoesNotRequestRAWDetail() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 6)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.setMode(.grid)
        let recorder = Recorder()
        let host = EventHostingView(rootView: Host(model: model, surface: .grid, recorder: recorder).frame(width: 780, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: 780, height: 500)
        let before = await ImagePipeline.shared.testingSnapshot()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let cards = descendants(host).compactMap { $0 as? CardInputView }
        XCTAssertGreaterThanOrEqual(cards.count, 2)
        try XCTUnwrap(cards.last).mouseDown(with: try mouseEvent())
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await ImagePipeline.shared.testingSnapshot()
        XCTAssertEqual(after.detailRequests, before.detailRequests)
        XCTAssertEqual(after.detailDecodeStarts, before.detailDecodeStarts)
        XCTAssertFalse(model.actualPixels)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

extension UIClickPerformanceTests {
    actor LatePreview {
        let firstID: String
        let old: NSImage
        let current: NSImage
        var suspended: CheckedContinuation<NSImage, Error>?
        var firstStarted = false
        var currentReturned = false
        init(firstID: String, old: NSImage, current: NSImage) { self.firstID = firstID; self.old = old; self.current = current }
        func preview(_ asset: AssetRecord) async throws -> NSImage {
            if asset.id == firstID {
                firstStarted = true
                // Deliberately ignores task cancellation, as a CPU/GPU decode can do.
                return try await withCheckedThrowingContinuation { suspended = $0 }
            }
            currentReturned = true; return current
        }
        func releaseOld() { suspended?.resume(returning: old); suspended = nil }
    }
    struct PanelHost: View {
        @ObservedObject var model: AppModel
        let loader: PanelImageLoader
        var body: some View {
            Group {
                if let asset = model.focusedAsset { ImagePanel(asset: asset, actualPixels: false, sharedTransform: nil, loader: loader) }
            }.environmentObject(model).frame(width: 300, height: 300)
        }
    }
    @MainActor func testLateCancelledPreviewCannotReplaceNewFocusedImage() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 2)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let old = model.assets[0], current = model.assets[1]
        model.select(old)
        let loader = LatePreview(firstID: old.id, old: try solidImage(red: 255, blue: 0), current: try solidImage(red: 0, blue: 255))
        let boundary = PanelImageLoader(preview: { asset, _ in try await loader.preview(asset) }, detail: { _ in throw NSError(domain: "unexpected-detail-request", code: 1) })
        let host = NSHostingView(rootView: PanelHost(model: model, loader: boundary))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<200 { if await loader.firstStarted { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let firstStarted = await loader.firstStarted
        XCTAssertTrue(firstStarted)
        model.select(current)
        for _ in 0..<200 { if await loader.currentReturned { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let currentReturned = await loader.currentReturned
        XCTAssertTrue(currentReturned)
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = try panelCenter(host)
        XCTAssertGreaterThan(before.blueComponent, 0.95)
        XCTAssertLessThan(before.redComponent, 0.05)
        await loader.releaseOld()
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = try panelCenter(host)
        XCTAssertGreaterThan(after.blueComponent, 0.95, "Late old preview must not replace the current blue image")
        XCTAssertLessThan(after.redComponent, 0.05)
        XCTAssertEqual(model.focusedID, current.id)
    }
    @MainActor private func solidImage(red: UInt8, blue: UInt8) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 80, bitsPerPixel: 32))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for index in stride(from: 0, to: 1600, by: 4) { bytes[index] = red; bytes[index + 1] = 0; bytes[index + 2] = blue; bytes[index + 3] = 255 }
        let image = NSImage(size: CGSize(width: 20, height: 20)); image.addRepresentation(bitmap); return image
    }
    @MainActor private func panelCenter(_ host: NSView) throws -> NSColor {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 3)?.usingColorSpace(.deviceRGB))
    }
}

// Optional synthetic background IO. Production sources are intentionally not instrumented:
// file-level scan progress is distinct from exact SHA256 chunk/CPU occupancy.
extension UIClickPerformanceTests {
    enum RelocationWorkloadError: Error {
        case externalLibraryForbidden, failedToStart(String), activityTimeout
    }
    struct RelocationPayload {
        let sessionID: String
        let assetID: String
        let expectedHash: String
        let root: URL
        let payloadBytes: Int
        let candidateEntries: Int
    }
    struct RelocationSampleEvidence: Encodable {
        let jobRunningAtEvent: Bool
        let scannedEntriesAtEvent: Int
        let scanCycleAtEvent: Int
        let jobRunningWhenCollected: Bool
        let scannedEntriesWhenCollected: Int
    }
    struct RelocationProgressEvidence: Encodable {
        let uptimeSeconds: Double
        let scanCycle: Int
        let cumulativeScannedEntries: Int
        let newlyReportedEntries: Int
    }
    struct RelocationScanInterval: Encodable {
        let cycle: Int
        let startedUptimeSeconds: Double
        var endedUptimeSeconds: Double?
        var terminalStatus: String?
        var persistedMatchingCandidates = 0
    }
    struct RelocationWorkloadReport: Encodable {
        let kind = "AppModel.startRelocation → real RelocationService fresh read-only scans; never confirm"
        let fixture = "one generated 256MiB file, 128 hard-link candidates on the local temporary volume; synthetic cached filesystem IO/SHA256, not real RAW decoding"
        let evidenceBoundary = "Service progress counts size-matched entries after a hash attempt, not instrumented hash chunks. Fresh scans have no reused candidate cache. Persisted candidates with the expected contentHash separately prove completed full SHA256 matches; candidate cap may undercount work. No byte throughput or instantaneous hash occupancy is inferred."
        let setupExcluded = "Payload generation, initial import/hash and hard-link creation finish before workload start and timed click samples"
        let payloadBytes: Int
        let candidateDirectoryEntries: Int
        let scanCyclesStarted: Int
        let scanCyclesFinished: Int
        let serviceIntervals: [RelocationScanInterval]
        let serviceActiveFractionDuringMeasurement: Double
        let samplesWithActiveJobAtEvent: Int
        let samplesWithActiveJobWhenCollected: Int
        let totalSamples: Int
        let progressEntriesWithinMeasurement: Int
        let progressEventsWithinMeasurement: Int
        let maxProgressGapDuringMeasurementMs: Double
        let persistedFullHashCandidateEvidenceCount: Int
        let progress: [RelocationProgressEvidence]
        let cancelledAndJoined: Bool
        let photoRecordsUnchanged: Bool
        let groupRecordsUnchanged: Bool
        let failures: [String]
    }

    @MainActor private func prepareRelocationPayload(_ fixture: AppModelTests.Fixture) async throws -> RelocationPayload {
        let source = fixture.root.appendingPathComponent("synthetic-relocation-source")
        let scan = fixture.root.appendingPathComponent("synthetic-relocation-candidates")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("synthetic-load.ARW")
        let size = 256 * 1024 * 1024, entries = 128
        // Bounded setup allocation; bytes are deliberately not valid camera RAW data.
        let chunk = Data(repeating: 0x5a, count: 1024 * 1024)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        do {
            for _ in 0..<256 { try handle.write(contentsOf: chunk) }
            try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); throw error }
        let session = try await ImportService(store: fixture.store).importDirectory(source: source, destination: nil, projectName: "Synthetic relocation load", mode: .reference, progress: { _ in })
        let asset = try XCTUnwrap(try fixture.store.loadAssets(sessionID: session.id).first)
        let hash = try XCTUnwrap(asset.contentHash)
        XCTAssertEqual(asset.fileSize, Int64(size))
        for index in 0..<entries {
            try FileManager.default.linkItem(at: file, to: scan.appendingPathComponent(String(format: "%04d.bin", index)))
        }
        return RelocationPayload(sessionID: session.id, assetID: asset.id, expectedHash: hash, root: scan, payloadBytes: size, candidateEntries: entries)
    }

    @MainActor final class RelocationWorkload {
        let model: AppModel
        let payload: RelocationPayload
        private var task: Task<Void, Never>?
        private var observation: AnyCancellable?
        private var stopping = false
        private var currentScannedEntries = 0
        private(set) var totalScannedEntries = 0
        private var cycle = 0
        private var completedCycles = 0
        private var progress: [RelocationProgressEvidence] = []
        private var intervals: [RelocationScanInterval] = []
        private var failures: [String] = []
        private var joined = false
        init(model: AppModel, payload: RelocationPayload) {
            self.model = model; self.payload = payload
            observation = model.$progress.sink { [weak self] value in
                guard let self, let value, value.title == "只读查找", value.completed > self.currentScannedEntries else { return }
                let delta = value.completed - self.currentScannedEntries
                self.currentScannedEntries = value.completed; self.totalScannedEntries += delta
                self.progress.append(RelocationProgressEvidence(uptimeSeconds: ProcessInfo.processInfo.systemUptime, scanCycle: self.cycle, cumulativeScannedEntries: self.totalScannedEntries, newlyReportedEntries: delta))
            }
        }
        func start() {
            guard task == nil else { return }
            task = Task { [self] in
                while !stopping {
                    cycle += 1; currentScannedEntries = 0
                    model.prepareRelocation(sessionID: payload.sessionID, assetIDs: [payload.assetID], role: .source)
                    intervals.append(RelocationScanInterval(cycle: cycle, startedUptimeSeconds: ProcessInfo.processInfo.systemUptime))
                    model.startRelocation(root: payload.root)
                    guard model.isBusy else { failures.append("Controller did not start the relocation job"); break }
                    while model.isBusy { try? await Task.sleep(nanoseconds: 2_000_000) }
                    intervals[intervals.count - 1].endedUptimeSeconds = ProcessInfo.processInfo.systemUptime
                    intervals[intervals.count - 1].terminalStatus = model.relocationReport?.status
                    let candidates = model.relocationReport?.items.first { $0.assetID == payload.assetID }?.candidates ?? []
                    intervals[intervals.count - 1].persistedMatchingCandidates = candidates.filter { $0.contentHash == payload.expectedHash }.count
                    completedCycles += 1
                    if let error = model.errorMessage { failures.append(error); break }
                    if !stopping && model.relocationReport?.scanComplete != true { failures.append("Background scan unexpectedly stopped before the benchmark requested cancellation"); break }
                    // A fresh scan intentionally rehashes candidates rather than resume's evidence cache.
                }
            }
        }
        func waitForActiveScan() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while ProcessInfo.processInfo.systemUptime < deadline {
                if !failures.isEmpty { throw RelocationWorkloadError.failedToStart(failures.joined(separator: "; ")) }
                if model.relocationIsRunning && currentScannedEntries > 0 { return }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            throw RelocationWorkloadError.activityTimeout
        }
        func sampleEvidence() -> RelocationSampleEvidence {
            RelocationSampleEvidence(jobRunningAtEvent: model.relocationIsRunning, scannedEntriesAtEvent: totalScannedEntries, scanCycleAtEvent: cycle, jobRunningWhenCollected: false, scannedEntriesWhenCollected: totalScannedEntries)
        }
        func requestStop() { stopping = true; model.cancelJob() }
        func stop() async {
            requestStop()
            await task?.value
            joined = !model.isBusy
            observation?.cancel(); observation = nil
        }
        func report(samples: [Sample], photoRecordsUnchanged: Bool, groupRecordsUnchanged: Bool) -> RelocationWorkloadReport {
            let first = samples.map(\.eventUptimeSeconds).min() ?? 0
            let last = samples.map(\.viewUpdateUptimeSeconds).max() ?? first
            let matching = progress.filter { $0.uptimeSeconds >= first && $0.uptimeSeconds <= last }
            let span = max(0.000001, last - first)
            let active = intervals.reduce(0.0) { partial, item in
                partial + max(0, min(last, item.endedUptimeSeconds ?? last) - max(first, item.startedUptimeSeconds))
            }
            let boundaries = [first] + matching.map(\.uptimeSeconds) + [last]
            let maxGap = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.max() ?? 0
            return RelocationWorkloadReport(payloadBytes: payload.payloadBytes, candidateDirectoryEntries: payload.candidateEntries, scanCyclesStarted: cycle, scanCyclesFinished: completedCycles, serviceIntervals: intervals, serviceActiveFractionDuringMeasurement: min(1, active / span), samplesWithActiveJobAtEvent: samples.filter { $0.relocation?.jobRunningAtEvent == true }.count, samplesWithActiveJobWhenCollected: samples.filter { $0.relocation?.jobRunningWhenCollected == true }.count, totalSamples: samples.count, progressEntriesWithinMeasurement: matching.reduce(0) { $0 + $1.newlyReportedEntries }, progressEventsWithinMeasurement: matching.count, maxProgressGapDuringMeasurementMs: maxGap * 1000, persistedFullHashCandidateEvidenceCount: intervals.reduce(0) { $0 + $1.persistedMatchingCandidates }, progress: progress, cancelledAndJoined: joined, photoRecordsUnchanged: photoRecordsUnchanged, groupRecordsUnchanged: groupRecordsUnchanged, failures: failures)
        }
    }
}
