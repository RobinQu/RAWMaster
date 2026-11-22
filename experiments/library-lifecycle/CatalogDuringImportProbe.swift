import Foundation
import RAWMasterCore
import RAWMasterImaging
import XCTest
@testable import RAWMaster

/// Run only inside a private test checkout with a standalone v7 catalog backup.
final class CatalogDuringImportProbe: XCTestCase {
    private struct Observation: Codable {
        var ms: Double
        var matches: Int
    }

    private func read(_ store: LibraryStore) throws -> Observation {
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try LibrarySnapshot.read(store: store, groupingSessionID: nil)
        let admitted = Set(snapshot.admissions.map(\.assetID))
        let scope = snapshot.assets.filter { admitted.contains($0.id) }
        let results = try AssetSearchEngine.filter(assets: scope, query: .init(minimumRating: 4),
            tags: snapshot.assetTags, reviewedIDs: Set(snapshot.reviewRecords.filter(\.reviewed).map(\.assetID)),
            sort: .capturedDescending, colorLabels: snapshot.assetColorLabels)
        return Observation(ms: (ProcessInfo.processInfo.systemUptime - start) * 1_000, matches: results.count)
    }

    private struct Trial: Codable {
        var idle: [Observation]
        var duringImport: [Observation]
        var importedFiles: Int
        var importSeconds: Double
    }

    func testSnapshotAndRatingDuringRealImport() async throws {
        let environment = ProcessInfo.processInfo.environment
        func location(_ key: String) throws -> URL {
            guard let value = environment[key] else { throw XCTSkip("Missing research input " + key) }
            return URL(fileURLWithPath: value)
        }
        let snapshot = try location("RM_CATALOG_BACKUP")
        let rawFolder = try location("RAWMASTER_RUNTIME_RAW_DIRECTORY")
        let tool = try location("RAWMASTER_RUNTIME_TOOL_ROOT")
        let output = try location("RM_CONCURRENT_REPORT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rm-catalog-trial-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var trials: [Trial] = []
        for index in 0..<4 {
            let database = root.appendingPathComponent("trial-\(index).sqlite")
            try fm.copyItem(at: snapshot, to: database)
            let store = try LibraryStore(databaseURL: database)
            let importer = ImportService(store: store, postIngest: RuntimeAutomaticGroupingCoordinator.callback(
                store: store, libraryURL: database, toolRoot: tool))
            let idle = try (0..<5).map { _ in try read(store) }
            let start = ProcessInfo.processInfo.systemUptime
            let reader = Task.detached {
                var observed: [(Double, Observation)] = []
                while !Task.isCancelled {
                    let sample = try self.read(store)
                    observed.append((ProcessInfo.processInfo.systemUptime, sample))
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                return observed
            }
            defer { reader.cancel() }
            let session = try await importer.importDirectory(source: rawFolder, destination: nil,
                projectName: "Concurrent read probe", mode: .reference, initialScreening: true, progress: { _ in })
            let finish = ProcessInfo.processInfo.systemUptime
            reader.cancel()
            let during = try await reader.value.filter { $0.0 <= finish }.map { $0.1 }
            XCTAssertFalse(during.isEmpty)
            XCTAssertEqual(Set((idle + during).map(\.matches)).count, 1)
            let files = try store.loadAssets(sessionID: session.id).count
            XCTAssertEqual(files, 6)
            trials.append(Trial(idle: idle, duringImport: during, importedFiles: files, importSeconds: finish - start))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trials).write(to: output, options: .withoutOverwriting)
    }
}
