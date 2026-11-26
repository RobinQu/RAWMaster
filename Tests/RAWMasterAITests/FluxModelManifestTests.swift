import CryptoKit
import XCTest
@testable import RAWMasterAI

final class FluxModelManifestTests: XCTestCase {
    func testBundledManifestIdentity() throws {
        let manifest = try FluxModelManifest.bundled()
        XCTAssertEqual(manifest.revision, "d9790a1ceaba200e8b773fb236f7c9fa754283a7")
        XCTAssertEqual(manifest.repoID, "devin-lai/flux-3-image-klein-mlx-q8")
        XCTAssertEqual(manifest.files.count, 102)
        XCTAssertEqual(manifest.totalBytes, 10_281_769_642)
        XCTAssertEqual(Set(manifest.files.map(\.path)).count, 102)
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 })
        XCTAssertFalse(FluxModelManager.licenseText()?.isEmpty ?? true)
        let sample = try XCTUnwrap(manifest.files.first { $0.path == "q8/manifest.json" })
        XCTAssertEqual(
            manifest.remoteURL(for: sample)?.absoluteString,
            "https://huggingface.co/devin-lai/flux-3-image-klein-mlx-q8/resolve/d9790a1ceaba200e8b773fb236f7c9fa754283a7/q8/manifest.json"
        )
    }

    @MainActor
    func testEmptyManagerAndLicense() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FluxModelManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = FluxModelManager(root: root, defaults: defaults)
        XCTAssertEqual(manager.status, .notInstalled)
        XCTAssertEqual(manager.completedBytes, 0)
        XCTAssertFalse(manager.isReady)
        XCTAssertFalse(manager.licenseAccepted)
        manager.setLicenseAccepted(true)
        XCTAssertTrue(manager.licenseAccepted)
        XCTAssertTrue(manager.canStart)
        XCTAssertFalse(FluxModelManager.installed(at: root))
    }

    @MainActor
    func testLiveSingleFileDownloadIfEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RAWMASTER_LIVE_FLUX_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set RAWMASTER_LIVE_FLUX_DOWNLOAD=1 to exercise the HTTPS manifest download")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxDownload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FluxDownloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FluxModelManifest.File(
            path: ".gitattributes",
            bytes: 134,
            sha256: "73c5e13e0be40d54ddab649478a43fa2c0fd578fc5ecb3d14bbc048d6a3a2ecd"
        )
        let manifest = FluxModelManifest(
            schemaVersion: 1,
            repoID: "devin-lai/flux-3-image-klein-mlx-q8",
            revision: "d9790a1ceaba200e8b773fb236f7c9fa754283a7",
            modelID: "black-forest-labs/flux-3-image-klein",
            license: "FLUX Kommunity License v.1.0",
            licenseURL: URL(string: "https://huggingface.co/devin-lai/flux-3-image-klein-mlx-q8/blob/d9790a1ceaba200e8b773fb236f7c9fa754283a7/LICENSE.md")!,
            totalBytes: file.bytes,
            files: [file]
        )
        let manager = FluxModelManager(manifest: manifest, root: root, defaults: defaults)
        manager.setLicenseAccepted(true)
        manager.start()
        for _ in 0..<120 {
            if manager.status == .ready || manager.status == .failed { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        let saved = try Data(contentsOf: root.appendingPathComponent(file.path))
        XCTAssertEqual(saved.count, Int(file.bytes))
        XCTAssertEqual(SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined(), file.sha256)
    }

    @MainActor
    func testLiveFullManifestDownloadIfEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RAWMASTER_LIVE_FLUX_FULL_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set RAWMASTER_LIVE_FLUX_FULL_DOWNLOAD=1 to download and verify all 102 model files")
        }
        let retainedRoot = ProcessInfo.processInfo.environment["RAWMASTER_LIVE_FLUX_FULL_DOWNLOAD_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = retainedRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxFullDownload-\(UUID().uuidString)", isDirectory: true)
        defer {
            if retainedRoot == nil { try? FileManager.default.removeItem(at: root) }
        }
        let suite = "FluxFullDownloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = FluxModelManager(root: root, defaults: defaults)
        let manifest = try XCTUnwrap(manager.manifest)
        XCTAssertFalse(manager.isReady)
        manager.setLicenseAccepted(true)
        XCTAssertTrue(manager.canStart)
        let started = Date()
        manager.start()
        var lastReported = -1
        while manager.status == .downloading || manager.status == .verifying {
            let percent = Int(manager.progress * 100)
            if percent / 10 != lastReported / 10 {
                lastReported = percent
                print("FLUX download \(percent)% · \(manager.completedBytes)/\(manifest.totalBytes) · \(manager.currentFile)")
            }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(manager.completedBytes, manifest.totalBytes)
        XCTAssertEqual(manager.progress, 1)
        let fm = FileManager.default
        for file in manifest.files {
            let url = root.appendingPathComponent(file.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            XCTAssertEqual(Int64(size ?? -1), file.bytes, file.path)
            XCTAssertEqual(try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(), file.sha256, file.path)
        }
        print("FLUX full download verified \(manifest.files.count) files · \(manifest.totalBytes) bytes · \(Int(Date().timeIntervalSince(started)))s")
        await manager.verify()
        XCTAssertEqual(manager.status, .ready)
    }

    @MainActor
    func testLiveRangeResumeIfEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RAWMASTER_LIVE_FLUX_RANGE_RESUME"] == "1" else {
            throw XCTSkip("Set RAWMASTER_LIVE_FLUX_RANGE_RESUME=1 to exercise a real HTTP Range resume")
        }
        let modelRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["RAWMASTER_LIVE_FLUX_MODEL"])
        let bundled = try FluxModelManifest.bundled()
        let path = "q8/transformer/single_blocks.14.safetensors"
        let file = try XCTUnwrap(bundled.files.first { $0.path == path })
        let source = URL(fileURLWithPath: modelRoot).appendingPathComponent(path)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let prefix = try XCTUnwrap(handle.read(upToCount: 1_048_576))

        let manifest = FluxModelManifest(
            schemaVersion: 1, repoID: bundled.repoID, revision: bundled.revision,
            modelID: bundled.modelID, license: bundled.license, licenseURL: bundled.licenseURL,
            totalBytes: file.bytes, files: [file]
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxRangeLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let part = root.appendingPathComponent(path).appendingPathExtension("part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prefix.write(to: part)
        let suite = "FluxRangeLive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = DownloadRecorder()
        let manager = FluxModelManager(manifest: manifest, root: root, defaults: defaults) { request in
            let remote = try XCTUnwrap(request.url)
            let range = request.value(forHTTPHeaderField: "Range")
            await calls.record(path, range: range)
            let (data, response) = try await URLSession.shared.data(for: request)
            await calls.recordStatus(path, (response as? HTTPURLResponse)?.statusCode ?? -1)
            return (data, response)
        }
        manager.setLicenseAccepted(true)
        manager.start()
        let deadline = Date().addingTimeInterval(900)
        while manager.status == .downloading, Date() < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        let saved = try Data(contentsOf: root.appendingPathComponent(path))
        XCTAssertEqual(saved.count, Int(file.bytes))
        XCTAssertEqual(SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined(), file.sha256)
        let ranges = await calls.ranges(for: path)
        let statuses = await calls.statuses(for: path)
        XCTAssertEqual(ranges.first, "bytes=1048576-\(1048576 + 32 * 1024 * 1024 - 1)")
        XCTAssertEqual(statuses.first, 206)
    }

    func testInstalledChecksRequiredFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxModelFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["q8/manifest.json", "vae-fp32/vae.safetensors", "assets/tokenizer.json"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
        XCTAssertTrue(FluxModelManager.installed(at: root))
    }
}

@MainActor
final class FluxModelManagerStateTests: XCTestCase {
    private struct Fixture {
        let manifest: FluxModelManifest
        let payloads: [String: Data]
    }

    private func fixture() -> Fixture {
        let payloads = [
            "q8/manifest.json": Data(#"{"model":"flux-3"}"#.utf8),
            "vae-fp32/vae.safetensors": Data("vae-weights".utf8),
            "assets/tokenizer.json": Data("tokenizer".utf8),
        ]
        let files = payloads.keys.sorted().map {
            FluxModelManifest.File(path: $0, bytes: Int64(payloads[$0]!.count),
                                   sha256: SHA256.hash(data: payloads[$0]!).map { String(format: "%02x", $0) }.joined())
        }
        return Fixture(
            manifest: FluxModelManifest(
                schemaVersion: 1, repoID: "example/flux", revision: "test-revision",
                modelID: "example/flux-3", license: "Test License",
                licenseURL: URL(string: "https://example.com/license")!,
                totalBytes: files.reduce(0) { $0 + $1.bytes }, files: files
            ),
            payloads: payloads
        )
    }

    private func makeManager(_ fixture: Fixture, root: URL, defaults: UserDefaults,
                             chunkBytes: Int64 = 32 * 1024 * 1024,
                             downloader: @escaping FluxModelFileDownloader) -> FluxModelManager {
        FluxModelManager(manifest: fixture.manifest, root: root, defaults: defaults,
                         downloadFile: downloader, chunkBytes: chunkBytes)
    }

    private func write(_ files: [String: Data], to root: URL) throws {
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private func temporaryDefaults() throws -> (UserDefaults, String) {
        let suite = "FluxModelManagerStateTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for manager state")
    }

    func testResumeSkipsCompletedFilesWithoutDoubleCounting() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxResume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let completed = ["assets/tokenizer.json", "q8/manifest.json"]
        try write(Dictionary(uniqueKeysWithValues: completed.map { ($0, fixture.payloads[$0]!) }), to: root)
        let calls = DownloadRecorder()
        let manifest = fixture.manifest
        let payloads = fixture.payloads
        let manager = makeManager(fixture, root: root, defaults: defaults) { request in
            let remote = try XCTUnwrap(request.url)
            let file = try XCTUnwrap(manifest.files.first { manifest.remoteURL(for: $0) == remote })
            await calls.record(file.path)
            return (payloads[file.path]!, HTTPURLResponse(url: remote, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        manager.setLicenseAccepted(true)
        manager.start()
        await waitUntil { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(manager.completedBytes, manifest.totalBytes)
        XCTAssertEqual(manager.progress, 1)
        let requested = await calls.paths
        XCTAssertEqual(requested, ["vae-fp32/vae.safetensors"])
    }

    func testTransientDownloadFailureRetriesTheFile() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = DownloadRecorder()
        let manifest = fixture.manifest
        let payloads = fixture.payloads
        let flaky = "assets/tokenizer.json"
        let manager = makeManager(fixture, root: root, defaults: defaults) { request in
            let remote = try XCTUnwrap(request.url)
            let file = try XCTUnwrap(manifest.files.first { manifest.remoteURL(for: $0) == remote })
            let attempt = await calls.record(file.path)
            if file.path == flaky && attempt == 1 {
                throw URLError(.networkConnectionLost)
            }
            return (payloads[file.path]!, HTTPURLResponse(url: remote, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        manager.setLicenseAccepted(true)
        manager.start()
        await waitUntil(timeout: 15) { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(manager.completedBytes, manifest.totalBytes)
        let flakyCalls = await calls.count(flaky)
        XCTAssertEqual(flakyCalls, 2)
    }

    func testDownloadCompletesWithoutSettingsObservers() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxBackground-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = fixture.manifest
        let payloads = fixture.payloads
        let manager = makeManager(fixture, root: root, defaults: defaults, chunkBytes: 4) { request in
            try await Task.sleep(for: .milliseconds(30))
            let remote = try XCTUnwrap(request.url)
            let file = try XCTUnwrap(manifest.files.first { manifest.remoteURL(for: $0) == remote })
            let payload = payloads[file.path]!
            let range = request.value(forHTTPHeaderField: "Range")
            guard let range, range.hasPrefix("bytes=") else {
                return (payload, HTTPURLResponse(url: remote, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let bounds = range.dropFirst(6).split(separator: "-")
            let start = try XCTUnwrap(Int(bounds[0]))
            let end = min(try XCTUnwrap(Int(bounds[1])), payload.count - 1)
            let chunk = payload.subdata(in: start..<(end + 1))
            let header = ["Content-Range": "bytes \(start)-\(end)/\(payload.count)"]
            return (chunk, HTTPURLResponse(url: remote, statusCode: 206, httpVersion: nil, headerFields: header)!)
        }
        manager.setLicenseAccepted(true)
        manager.start()
        await waitUntil { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(manager.completedBytes, manifest.totalBytes)
    }

    func testPartialFileResumesWithRangeAndNewManager() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxRange-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let finished = "assets/tokenizer.json"
        let partial = "q8/manifest.json"
        try write([finished: fixture.payloads[finished]!], to: root)
        let partialPayload = fixture.payloads[partial]!
        let part = root.appendingPathComponent(partial).appendingPathExtension("part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(partialPayload.prefix(5)).write(to: part)

        let firstManager = makeManager(fixture, root: root, defaults: defaults) { _ in
            throw FluxModelError.downloadFailed("not started")
        }
        XCTAssertEqual(firstManager.status, .paused)
        XCTAssertEqual(firstManager.completedBytes, Int64(fixture.payloads[finished]!.count) + 5)

        let calls = DownloadRecorder()
        let manifest = fixture.manifest
        let payloads = fixture.payloads
        let manager = makeManager(fixture, root: root, defaults: defaults, chunkBytes: 4) { request in
            let remote = try XCTUnwrap(request.url)
            let file = try XCTUnwrap(manifest.files.first { manifest.remoteURL(for: $0) == remote })
            let range = request.value(forHTTPHeaderField: "Range")
            await calls.record(file.path, range: range)
            let payload = payloads[file.path]!
            guard let range, range.hasPrefix("bytes=") else {
                return (payload, HTTPURLResponse(url: remote, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let bounds = range.dropFirst(6).split(separator: "-")
            let start = try XCTUnwrap(Int(bounds[0]))
            let end = min(try XCTUnwrap(Int(bounds[1])), payload.count - 1)
            let chunk = payload.subdata(in: start..<(end + 1))
            let header = ["Content-Range": "bytes \(start)-\(end)/\(payload.count)"]
            return (chunk, HTTPURLResponse(url: remote, statusCode: 206, httpVersion: nil, headerFields: header)!)
        }
        manager.setLicenseAccepted(true)
        manager.start()
        await waitUntil { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(manager.completedBytes, manifest.totalBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(partial)), partialPayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        let ranges = await calls.ranges(for: partial)
        XCTAssertEqual(ranges.first, "bytes=5-8")
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertTrue(ranges.allSatisfy { $0.hasPrefix("bytes=") })
    }

    func testPauseAndResumeKeepsCompletedFilesAndRetriesUnfinishedFile() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxPause-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = DownloadRecorder()
        let manifest = fixture.manifest
        let payloads = fixture.payloads
        let slowPath = "vae-fp32/vae.safetensors"
        let manager = makeManager(fixture, root: root, defaults: defaults) { request in
            let remote = try XCTUnwrap(request.url)
            let file = try XCTUnwrap(manifest.files.first { manifest.remoteURL(for: $0) == remote })
            let attempt = await calls.record(file.path)
            if file.path == slowPath && attempt == 1 {
                try await Task.sleep(for: .seconds(30))
            }
            return (payloads[file.path]!, HTTPURLResponse(url: remote, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        manager.setLicenseAccepted(true)
        manager.start()
        await waitUntil { await calls.count(slowPath) >= 1 }
        manager.pause()
        XCTAssertEqual(manager.status, .paused)
        let first = try XCTUnwrap(manifest.files.first { $0.path == "assets/tokenizer.json" })
        let completedBeforeSlow = manifest.files.filter { $0.path != slowPath }.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(manager.completedBytes, completedBeforeSlow)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.path).path))

        manager.resume()
        await waitUntil { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(manager.completedBytes, manifest.totalBytes)
        let tokenizerCalls = await calls.count("assets/tokenizer.json")
        let slowCalls = await calls.count(slowPath)
        let manifestCalls = await calls.count("q8/manifest.json")
        XCTAssertEqual(tokenizerCalls, 1)
        XCTAssertEqual(slowCalls, 2)
        XCTAssertEqual(manifestCalls, 1)
    }

    func testLicenseGateAndDeletion() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxDelete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try write(fixture.payloads, to: root)
        try Data("{}".utf8).write(to: root.appendingPathComponent("ready.json"))
        let manager = makeManager(fixture, root: root, defaults: defaults) { _ in
            throw FluxModelError.downloadFailed("unexpected download")
        }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertFalse(manager.licenseAccepted)
        XCTAssertFalse(manager.canStart)
        manager.start()
        XCTAssertEqual(manager.status, .ready, "Start must be gated while the license is unaccepted")
        manager.setLicenseAccepted(true)
        XCTAssertTrue(manager.licenseAccepted)
        await manager.delete()
        XCTAssertEqual(manager.status, .notInstalled)
        XCTAssertEqual(manager.completedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(manager.canStart)
    }

    func testVerifyWritesMarkerAndRemovesCorruptFile() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxVerify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try write(fixture.payloads, to: root)
        let manager = makeManager(fixture, root: root, defaults: defaults) { _ in
            throw FluxModelError.downloadFailed("unexpected download")
        }
        await manager.verify()
        XCTAssertEqual(manager.status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path))

        let corrupt = root.appendingPathComponent("assets/tokenizer.json")
        try Data("corrupt!!".utf8).write(to: corrupt)
        XCTAssertEqual(try Data(contentsOf: corrupt).count, fixture.payloads["assets/tokenizer.json"]!.count)
        await manager.verify()
        XCTAssertEqual(manager.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path))
    }

    func testFirstRunPromptAppearsOnceAndNotWhenInstalled() throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxFirstRun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(fixture, root: root, defaults: defaults) { _ in
            throw FluxModelError.downloadFailed("unexpected download")
        }
        XCTAssertTrue(manager.shouldShowFirstRunPrompt)
        manager.markFirstRunPromptShown()
        XCTAssertFalse(manager.shouldShowFirstRunPrompt)
        let reopened = makeManager(fixture, root: root, defaults: defaults) { _ in
            throw FluxModelError.downloadFailed("unexpected download")
        }
        XCTAssertFalse(reopened.shouldShowFirstRunPrompt)

        try write(fixture.payloads, to: root)
        let installed = makeManager(fixture, root: root, defaults: defaults) { _ in
            throw FluxModelError.downloadFailed("unexpected download")
        }
        XCTAssertEqual(installed.status, .ready)
        XCTAssertFalse(installed.shouldShowFirstRunPrompt)
    }
}

private actor DownloadRecorder {
    private(set) var paths: [String] = []
    private var counts: [String: Int] = [:]
    private var recordedRanges: [(String, String)] = []
    private var recordedStatuses: [String: [Int]] = [:]

    func record(_ path: String, range: String? = nil) -> Int {
        paths.append(path)
        if let range { recordedRanges.append((path, range)) }
        counts[path, default: 0] += 1
        return counts[path]!
    }

    func count(_ path: String) async -> Int {
        counts[path, default: 0]
    }

    func ranges(for path: String) -> [String] {
        recordedRanges.filter { $0.0 == path }.map(\.1)
    }

    func recordStatus(_ path: String, _ status: Int) {
        recordedStatuses[path, default: []].append(status)
    }

    func statuses(for path: String) -> [Int] {
        recordedStatuses[path, default: []]
    }
}
