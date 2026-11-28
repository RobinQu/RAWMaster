import AppKit
import CSQLite
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

/// Opt-in visual evidence. Every database and imported file belongs to a new QA
/// fixture below the supplied output directory; the user's library is never read.
final class LibraryCatalogCaptureTests: XCTestCase {
    private struct Evidence: Codable {
        let filename: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
        let scope: String
        let mode: String
        let selectedFiles: Int
        let importCards: Int
        let sequenceCards: Int
        let reduceTransparency: Bool
        let increasedContrast: Bool
        let captureKind: String
        let explicitMaterialPolicy: String?
        let effectiveAppKitAppearance: String
        let effectiveWindowAppearance: String
        let effectiveApplicationAppearance: String
    }

    @MainActor private final class AccessibilityObservation {
        var sampled = false
        var reduceTransparency = false
        var increasedContrast = false
    }

    @MainActor private struct AccessibilityProbe: View {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        let observation: AccessibilityObservation

        var body: some View {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                .onAppear { record() }
                .onChange(of: reduceTransparency) { _ in record() }
                .onChange(of: contrast) { _ in record() }
        }

        private func record() {
            observation.sampled = true
            observation.reduceTransparency = reduceTransparency
            observation.increasedContrast = contrast == .increased
        }
    }

    private struct FixtureManifest: Codable {
        let fixtureDirectory: String
        let nativeLibrary: String
        let sessions: [String: String]
        let projects: [String: String]
        let groups: [String: String]
        let sourceImageDirectory: String?
        let sourcePairDirectory: String?
    }

    @MainActor func testOptionalLibraryCatalogCaptures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["RAWMASTER_CATALOG_CAPTURE_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_CATALOG_CAPTURE_OUTPUT for 012 catalog captures")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = output.appendingPathComponent("fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        // Keep fixture sources after the test so the exported native QA library
        // remains usable; only its independent preferences suite is temporary.
        let library = fixture.appendingPathComponent("library.sqlite")
        let store = try LibraryStore(databaseURL: library)
        let suite = "RAWMaster012Capture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let imageDirectory = environment["RAWMASTER_CATALOG_CAPTURE_IMAGES"]
        let pairDirectory = environment["RAWMASTER_CATALOG_CAPTURE_PAIR_SOURCE"]
        let existingImages = try imageDirectory.map { directory in
            try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isRegularFileKey])
                .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } ?? []
        if imageDirectory != nil { XCTAssertFalse(existingImages.isEmpty, "The optional photo fixture directory must contain JPEG files") }
        let names = ["山间晨光 · 秋日行摄", "云海流动 · 黄山延时", "城市蓝调 · 曝光包围", "海岸拾光 · 自选系列", "雨后街头 · 待初筛"]
        var sessions: [ImportSession] = []
        for (index, name) in names.enumerated() {
            let source = fixture.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for number in 1...4 {
                let target = source.appendingPathComponent(String(format: "DSC_%02d%02d.jpg", index + 1, number))
                if !existingImages.isEmpty { try FileManager.default.copyItem(at: existingImages[(index + number - 1) % existingImages.count], to: target) }
                else { try makeImage(index: index * 4 + number).write(to: target) }
            }
            if index == 0, let pairDirectory {
                let pairFiles = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: pairDirectory), includingPropertiesForKeys: [.isRegularFileKey])
                    .filter { ["dng", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                for file in pairFiles { try FileManager.default.copyItem(at: file, to: source.appendingPathComponent(file.lastPathComponent)) }
            }
            sessions.append(try await ImportService(store: store).importDirectory(source: source, destination: nil,
                projectName: name, mode: .reference, initialScreening: index == names.count - 1, progress: { _ in }))
        }
        let assets = try store.loadAssets()
        let primaryAssets = assets.filter { $0.sessionID == sessions[0].id }
        if let raw = primaryAssets.first(where: { $0.filename.lowercased().hasSuffix(".dng") }),
           let jpeg = primaryAssets.first(where: { $0.url.deletingPathExtension().lastPathComponent == raw.url.deletingPathExtension().lastPathComponent && ["jpg", "jpeg"].contains($0.url.pathExtension.lowercased()) }) {
            _ = try store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        }
        let groupNames = ["晨光飞鸟 · 连拍", "黄山云海 · 延时", "城市蓝调 · HDR", "海岸色彩 · 精选", "街头候选 · 初筛连拍"]
        let kinds = ["连拍", "延时", "HDR", "自选系列", "连拍"]
        var groupIDs: [String] = []
        for index in sessions.indices {
            let ids = assets.filter { $0.sessionID == sessions[index].id }.map(\.id)
            let preview = try store.previewGroupCommand(.create(assetIDs: ids, name: groupNames[index], kind: kinds[index]))
            _ = try store.commitGroupCommand(preview)
            groupIDs.append(try XCTUnwrap(store.loadGroups().first { $0.name == groupNames[index] }).id)
        }
        let model = AppModel(libraryURL: library, defaults: defaults)
        model.showSidebar = true; model.showInspector = true
        model.selectScope(.project, id: sessions[0].projectID)
        let candidates = model.browserAssets
        XCTAssertGreaterThanOrEqual(candidates.count, 4)
        for (index, asset) in candidates.prefix(4).enumerated() {
            model.setColorLabel([PhotoColorLabel.red, .green, .blue, .purple][index], assetIDs: [asset.id])
        }
        model.decideAsset(id: candidates[0].id, decision: .keep, rating: 4)
        model.decideAsset(id: candidates[1].id, rating: 3)
        var evidence: [Evidence] = []
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            model.openImportCatalog()
            XCTAssertEqual(model.importCatalogItems.count, 5)
            evidence.append(try await capture(model, output: output, dark: dark, name: "imports-" + suffix))
            model.openSequenceCatalog()
            XCTAssertEqual(model.sequenceCatalogItems.count, 4, "Staging groups belong to the import session, not the published sequence catalog")
            evidence.append(try await capture(model, output: output, dark: dark, name: "sequences-" + suffix))
            if !dark {
                model.sequenceCatalogType = .timelapse
                XCTAssertEqual(model.sequenceCatalogItems.count, 1)
                evidence.append(try await capture(model, output: output, dark: false, name: "sequences-timelapse-filter"))
                model.sequenceCatalogQuery = "没有匹配的序列"
                XCTAssertTrue(model.sequenceCatalogItems.isEmpty)
                evidence.append(try await capture(model, output: output, dark: false, name: "sequences-search-empty"))
                model.sequenceCatalogQuery = ""; model.sequenceCatalogType = .all
                model.openCatalogSession(id: sessions[4].id)
                XCTAssertTrue(model.isTriageScope)
                evidence.append(try await capture(model, output: output, dark: false, name: "import-triage-detail"))
                model.openCatalogSequence(id: groupIDs[0])
                XCTAssertEqual(model.scope, .group)
                evidence.append(try await capture(model, output: output, dark: false, name: "sequence-photo-grid"))
            }
            model.selectScope(.project, id: sessions[0].projectID)
            model.setMode(.grid); model.clearProjectSearch()
            model.selectedIDs = Set(candidates.prefix(3).map(\.id)); model.focusedID = candidates[0].id
            evidence.append(try await capture(model, output: output, dark: dark, name: "grid-selection-glass-" + suffix))
            if !dark {
                model.select(candidates[0]); model.setMode(.single)
                evidence.append(try await capture(model, output: output, dark: false, name: "single-photo-filmstrip"))
            }
            model.setMode(.grid)
            model.selectedIDs = Set(candidates.prefix(2).map(\.id)); model.focusedID = candidates[1].id
            model.setMode(.compare); model.comparisonMode = .rgb
            evidence.append(try await capture(model, output: output, dark: dark, name: "compare-" + suffix))
        }
        evidence.append(try await captureOpaqueComponent(model, output: output, assetIDs: Array(candidates.prefix(3)).map(\.id)))
        model.openImportCatalog(); model.saveBrowse(); model.flushProjectReviewState()
        let native = output.appendingPathComponent("native-library.sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: native.path), "Use a fresh output directory for each capture run")
        try backup(source: library, destination: native)
        XCTAssertEqual(try LibraryStore(databaseURL: native).loadAssets().count, assets.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: output.appendingPathComponent("capture-dimensions.json"))
        try encoder.encode(FixtureManifest(fixtureDirectory: fixture.path, nativeLibrary: native.path,
            sessions: Dictionary(uniqueKeysWithValues: zip(names, sessions.map(\.id))),
            projects: Dictionary(uniqueKeysWithValues: zip(names, sessions.map(\.projectID))),
            groups: Dictionary(uniqueKeysWithValues: zip(groupNames, groupIDs)),
            sourceImageDirectory: imageDirectory, sourcePairDirectory: pairDirectory))
            .write(to: output.appendingPathComponent("fixture-manifest.json"))
    }

    @MainActor private func capture(_ model: AppModel, output: URL, dark: Bool, name: String) async throws -> Evidence {
        let size = NSSize(width: 1100, height: 720)
        let appearanceName: NSAppearance.Name = dark ? .darkAqua : .aqua
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let observation = AccessibilityObservation()
        let content = WorkbenchView().environmentObject(model)
            .preferredColorScheme(dark ? .dark : .light)
            .background(AccessibilityProbe(observation: observation))
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance; host.appearance = appearance
        window.contentView = host; window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, size.width, accuracy: 0.01)
        XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.01)
        XCTAssertTrue(observation.sampled, "The SwiftUI accessibility environment must be observed, not assumed")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(Double(bitmap.pixelsWide) / size.width, Double(bitmap.pixelsHigh) / size.height, accuracy: 0.001)
        let filename = name + ".png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
        return Evidence(filename: filename, logicalWidth: host.bounds.width, logicalHeight: host.bounds.height,
            pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, appearance: dark ? "dark" : "light",
            scope: model.scope.rawValue, mode: model.mode.rawValue, selectedFiles: model.selectedIDs.count,
            importCards: model.importCatalogItems.count, sequenceCards: model.sequenceCatalogItems.count,
            reduceTransparency: observation.reduceTransparency, increasedContrast: observation.increasedContrast,
            captureKind: "workbench", explicitMaterialPolicy: nil, effectiveAppKitAppearance: host.effectiveAppearance.name.rawValue,
            effectiveWindowAppearance: window.effectiveAppearance.name.rawValue,
            effectiveApplicationAppearance: NSApp.effectiveAppearance.name.rawValue)
    }

    /// Explicit component evidence for the same production modifier selected by
    /// accessibility policy. It intentionally makes no claim about OS preferences:
    /// NSHostingView normalizes named high-contrast appearances in this harness.
    @MainActor private func captureOpaqueComponent(_ model: AppModel, output: URL, assetIDs: [String]) async throws -> Evidence {
        let size = NSSize(width: 1100, height: 240)
        let policy = FloatingControlSurfacePolicy.resolve(reduceTransparency: true, increasedContrast: false, supportsGlass: true)
        XCTAssertEqual(policy, .opaque)
        let observation = AccessibilityObservation()
        let content = VStack(alignment: .leading, spacing: 18) {
            Text("材质组件 · 不透明回退").font(.headline)
            HStack(spacing: 16) {
                Label("已选 \(assetIDs.count) 张", systemImage: "checkmark.circle").font(.caption.weight(.semibold))
                Divider().frame(height: 18)
                Button {} label: { Label("保留", systemImage: "flag.fill") }
                Button {} label: { Label("排除", systemImage: "xmark") }
                RatingButtons(rating: 4) { _ in }
                ColorLabelPicker(assetIDs: assetIDs, compact: true)
                Button {} label: { Label("创建序列", systemImage: "square.stack.3d.up") }
                Button {} label: { Label("批量导出", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 14)
            .modifier(ResolvedFloatingControlSurface(policy: policy))
            Text("显式渲染生产材质策略的 opaque 分支；此截图不代表系统辅助功能已开启。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: size.width, height: size.height, alignment: .leading)
        .background(AppPalette.canvas).environmentObject(model)
        .preferredColorScheme(.light)
        .background(AccessibilityProbe(observation: observation))
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(observation.sampled)
        XCTAssertEqual(host.bounds.width, size.width, accuracy: 0.01)
        XCTAssertEqual(host.bounds.height, size.height, accuracy: 0.01)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let filename = "material-opaque-policy-component.png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
        return Evidence(filename: filename, logicalWidth: host.bounds.width, logicalHeight: host.bounds.height,
            pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, appearance: "light",
            scope: "component", mode: "controls", selectedFiles: assetIDs.count, importCards: 0, sequenceCards: 0,
            reduceTransparency: observation.reduceTransparency, increasedContrast: observation.increasedContrast,
            captureKind: "explicitPolicyComponent", explicitMaterialPolicy: "opaque",
            effectiveAppKitAppearance: host.effectiveAppearance.name.rawValue,
            effectiveWindowAppearance: window.effectiveAppearance.name.rawValue,
            effectiveApplicationAppearance: NSApp.effectiveAppearance.name.rawValue)
    }

    private func backup(source: URL, destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(input); throw NSError(domain: "LibraryCatalogCapture.SQLite", code: 1)
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(output); throw NSError(domain: "LibraryCatalogCapture.SQLite", code: 2)
        }
        defer { sqlite3_close(output) }
        guard let transfer = sqlite3_backup_init(output, "main", input, "main") else { throw NSError(domain: "LibraryCatalogCapture.SQLite", code: 3) }
        let status = sqlite3_backup_step(transfer, -1), finish = sqlite3_backup_finish(transfer)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw NSError(domain: "LibraryCatalogCapture.SQLite", code: Int(status)) }
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LibraryCatalogCapture.SQLite", code: 4)
        }
    }

    @MainActor private func makeImage(index: Int) throws -> Data {
        let size = NSSize(width: 960, height: 640)
        let image = NSImage(size: size)
        image.lockFocus()
        let phase = CGFloat(index % 4) / 4
        let top = NSColor(calibratedHue: 0.55 + phase * 0.10, saturation: 0.45, brightness: 0.70, alpha: 1)
        let bottom = NSColor(calibratedHue: 0.09 + phase * 0.05, saturation: 0.28, brightness: 0.97, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 650 - phase * 260, y: 415, width: 58, height: 58)).fill()
        for layer in 0..<4 {
            NSColor(calibratedHue: 0.53 + phase * 0.10, saturation: 0.35, brightness: 0.24 + CGFloat(layer) * 0.10, alpha: 1).setFill()
            let path = NSBezierPath(); path.move(to: .zero)
            for step in 0...12 {
                let x = CGFloat(step) * 80
                let wave = sin(CGFloat(step + index + layer * 2) * 0.71) * 62
                path.line(to: NSPoint(x: x, y: 360 - CGFloat(layer) * 65 + wave))
            }
            path.line(to: NSPoint(x: 960, y: 0)); path.close(); path.fill()
        }
        ("RAWMaster QA · \(index)" as NSString).draw(at: NSPoint(x: 28, y: 25), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.65)])
        image.unlockFocus()
        let representation = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: representation))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]))
    }
}
