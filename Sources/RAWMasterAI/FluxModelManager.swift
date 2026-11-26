import Combine
import CryptoKit
import Foundation

public struct FluxModelManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }

    public let schemaVersion: Int
    public let repoID: String
    public let revision: String
    public let modelID: String
    public let license: String
    public let licenseURL: URL
    public let totalBytes: Int64
    public let files: [File]

    public static func bundled() throws -> FluxModelManifest {
        let candidates = [
            Bundle.module.url(forResource: "FluxModelManifest", withExtension: "json"),
            Bundle.module.url(forResource: "FluxModelManifest", withExtension: "json", subdirectory: "Resources"),
            Bundle.module.resourceURL?.appendingPathComponent("Resources/FluxModelManifest.json"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(FluxModelManifest.self, from: Data(contentsOf: url))
    }

    public func remoteURL(for file: File) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoID)/resolve/\(revision)/\(file.path)"
        return components.url
    }
}

public enum FluxModelStatus: String, Sendable {
    case notInstalled, downloading, paused, verifying, ready, failed
}

public typealias FluxModelFileDownloader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

@MainActor
public final class FluxModelManager: ObservableObject {
    public nonisolated static let defaultRoot: URL = {
        if let path = ProcessInfo.processInfo.environment["RAWMASTER_FLUX_MODEL_ROOT"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let revision = (try? FluxModelManifest.bundled())?.revision ?? "d9790a1ceaba200e8b773fb236f7c9fa754283a7"
        return base.appendingPathComponent("RAWMaster/Models/Flux3Klein", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }()

    public nonisolated static func installed(at root: URL = defaultRoot) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("q8/manifest.json").path)
            && fm.fileExists(atPath: root.appendingPathComponent("vae-fp32/vae.safetensors").path)
            && fm.fileExists(atPath: root.appendingPathComponent("assets/tokenizer.json").path)
    }

    public nonisolated static var licenseAccepted: Bool {
        guard let revision = (try? FluxModelManifest.bundled())?.revision else { return false }
        return UserDefaults.standard.bool(forKey: "flux.license.\(revision)")
    }

    public nonisolated static func licenseText() -> String? {
        let candidates = [
            Bundle.module.resourceURL?.appendingPathComponent("Resources/ModelLicenses/FLUX.3-LICENSE.md"),
            Bundle.module.resourceURL?.appendingPathComponent("ModelLicenses/FLUX.3-LICENSE.md"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        }
        return nil
    }

    public var shouldShowFirstRunPrompt: Bool {
        status == .notInstalled && !defaults.bool(forKey: firstRunPromptKey)
    }

    public func markFirstRunPromptShown() {
        defaults.set(true, forKey: firstRunPromptKey)
    }

    private var firstRunPromptKey: String {
        "flux.firstRunShown.\(manifest?.revision ?? "unknown")"
    }

    @Published public private(set) var status: FluxModelStatus = .notInstalled
    @Published public private(set) var completedBytes: Int64 = 0
    @Published public private(set) var currentFile: String = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var bytesPerSecond: Double = 0
    @Published public private(set) var licenseAccepted: Bool

    public let root: URL
    public let manifest: FluxModelManifest?
    public let totalBytes: Int64
    private let defaults: UserDefaults
    private let downloadFile: FluxModelFileDownloader
    private let chunkBytes: Int64
    private var task: Task<Void, Never>?
    private var runToken = UUID()
    private var startedAt: Date?

    public convenience init(root: URL = FluxModelManager.defaultRoot, defaults: UserDefaults = .standard) {
        self.init(manifest: try? FluxModelManifest.bundled(), root: root, defaults: defaults)
    }

    init(manifest: FluxModelManifest?, root: URL, defaults: UserDefaults,
         downloadFile: @escaping FluxModelFileDownloader = { try await URLSession.shared.data(for: $0) },
         chunkBytes: Int64 = 32 * 1024 * 1024) {
        self.root = root
        self.defaults = defaults
        self.downloadFile = downloadFile
        self.chunkBytes = max(1, chunkBytes)
        if let manifest {
            self.manifest = manifest
            self.totalBytes = manifest.totalBytes
            self.licenseAccepted = defaults.bool(forKey: "flux.license.\(manifest.revision)")
        } else {
            self.manifest = nil
            self.totalBytes = 0
            self.licenseAccepted = false
            self.errorMessage = "应用未包含固定版本的 FLUX 模型清单。"
        }
        refresh()
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    public var estimatedRemainingSeconds: Double? {
        guard bytesPerSecond > 1, totalBytes > completedBytes else { return nil }
        return Double(totalBytes - completedBytes) / bytesPerSecond
    }

    public var isReady: Bool { status == .ready }
    public var isBusy: Bool { status == .downloading || status == .verifying }
    public var canStart: Bool { manifest != nil && licenseAccepted && !isBusy && status != .ready }

    public func setLicenseAccepted(_ accepted: Bool) {
        guard let manifest else { return }
        if accepted {
            defaults.set(true, forKey: "flux.license.\(manifest.revision)")
        } else {
            defaults.removeObject(forKey: "flux.license.\(manifest.revision)")
            if status == .downloading { pause() }
        }
        licenseAccepted = accepted
    }

    public func refresh() {
        guard let manifest else {
            status = .failed
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("ready.json").path) {
            let complete = manifest.files.allSatisfy { file in
                (try? root.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map { Int64($0) == file.bytes } ?? false
            }
            if complete {
                status = .ready
                completedBytes = manifest.totalBytes
                errorMessage = nil
                return
            }
            try? fm.removeItem(at: root.appendingPathComponent("ready.json"))
        }
        var present: Int64 = 0
        var partial = false
        for file in manifest.files {
            let url = root.appendingPathComponent(file.path)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes {
                present += file.bytes
            } else if let size = try? url.appendingPathExtension("part").resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(size) > 0 {
                partial = true
                present += min(Int64(size), file.bytes)
            }
        }
        completedBytes = min(present, manifest.totalBytes)
        if present >= manifest.totalBytes, Self.installed(at: root) {
            status = .ready
        } else if present > 0 || partial {
            status = .paused
        } else {
            status = .notInstalled
        }
    }

    public func start() {
        guard canStart, let manifest else { return }
        guard hasDiskSpace(for: manifest) else {
            status = .failed
            errorMessage = "可用空间不足。请至少预留 \(ByteCountFormatter.string(fromByteCount: manifest.totalBytes - completedBytes + 2_000_000_000, countStyle: .file))。"
            return
        }
        errorMessage = nil
        status = .downloading
        currentFile = ""
        startedAt = Date()
        bytesPerSecond = 0
        task?.cancel()
        let token = UUID()
        runToken = token
        task = Task { [weak self] in
            await self?.run(manifest, token: token)
        }
    }

    public func pause() {
        guard status == .downloading else { return }
        runToken = UUID()
        task?.cancel()
        task = nil
        status = .paused
    }

    public func resume() {
        guard status == .paused else { return }
        start()
    }

    public func delete() async {
        runToken = UUID()
        task?.cancel()
        task = nil
        let fm = FileManager.default
        if let manifest {
            for file in manifest.files {
                let url = root.appendingPathComponent(file.path)
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: url.appendingPathExtension("part"))
            }
            try? fm.removeItem(at: root.appendingPathComponent("ready.json"))
            removeEmptyDirectories(under: root)
        } else {
            try? fm.removeItem(at: root)
        }
        completedBytes = 0
        currentFile = ""
        bytesPerSecond = 0
        errorMessage = nil
        status = .notInstalled
    }

    private func removeEmptyDirectories(under root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return }
        let directories = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.path.count > $1.path.count }
        for directory in directories {
            if let contents = try? fm.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
                try? fm.removeItem(at: directory)
            }
        }
        if let contents = try? fm.contentsOfDirectory(atPath: root.path), contents.isEmpty {
            try? fm.removeItem(at: root)
        }
    }

    public func verify() async {
        guard let manifest, Self.installed(at: root) else {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("ready.json"))
            refresh()
            status = .failed
            errorMessage = "模型文件不完整，不能校验。"
            return
        }
        status = .verifying
        errorMessage = nil
        let root = self.root
        let result: Result<Void, Error> = await Task.detached {
            do {
                for file in manifest.files {
                    let url = root.appendingPathComponent(file.path)
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          Int64(size) == file.bytes else {
                        throw FluxModelError.invalidFile(file.path)
                    }
                    guard try Self.hash(url) == file.sha256 else {
                        try? FileManager.default.removeItem(at: url)
                        throw FluxModelError.invalidFile(file.path)
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            writeReadyMarker(manifest)
            completedBytes = manifest.totalBytes
            status = .ready
        case .failure(let error):
            try? FileManager.default.removeItem(at: root.appendingPathComponent("ready.json"))
            refresh()
            status = .failed
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "模型文件校验失败。"
        }
    }

    private func run(_ manifest: FluxModelManifest, token: UUID) async {
        let fm = FileManager.default
        var downloadedThisRun: Int64 = 0
        completedBytes = 0
        do {
            for file in manifest.files {
                try Task.checkCancellation()
                guard runToken == token else { return }
                let final = root.appendingPathComponent(file.path)
                let part = final.appendingPathExtension("part")
                if let size = try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   Int64(size) == file.bytes {
                    completedBytes += file.bytes
                    continue
                }
                if let size = try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   Int64(size) == file.bytes {
                    if (try? Self.hash(part)) == file.sha256 {
                        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                        try fm.moveItem(at: part, to: final)
                        completedBytes += file.bytes
                        continue
                    }
                    try? fm.removeItem(at: part)
                }
                try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                currentFile = file.path
                guard let remote = manifest.remoteURL(for: file) else {
                    throw FluxModelError.invalidURL(file.path)
                }
                var request = URLRequest(url: remote)
                request.timeoutInterval = 120
                request.cachePolicy = .reloadIgnoringLocalCacheData
                var offset = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if offset > file.bytes {
                    try? fm.removeItem(at: part)
                    offset = 0
                }
                if offset > 0 { completedBytes += offset }
                if !fm.fileExists(atPath: part.path) {
                    guard fm.createFile(atPath: part.path, contents: Data()) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                var lastError: Error?
                var completed = false
                for attempt in 0..<3 {
                    do {
                        while offset < file.bytes {
                            try Task.checkCancellation()
                            guard runToken == token else { return }
                            let end = min(offset + chunkBytes, file.bytes) - 1
                            var chunk = request
                            chunk.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                            let (data, response) = try await downloadFile(chunk)
                            guard let http = response as? HTTPURLResponse else {
                                throw FluxModelError.downloadFailed(file.path)
                            }
                            switch http.statusCode {
                            case 206:
                                guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                                      let range = Self.contentRange(value),
                                      range.start == offset,
                                      range.end == offset + Int64(data.count) - 1,
                                      range.total == nil || range.total == file.bytes else {
                                    throw FluxModelError.downloadFailed(file.path)
                                }
                            case 200:
                                // The server ignored Range. Discard only the partial
                                // bytes and restart this file from the full response.
                                if offset > 0 {
                                    try? fm.removeItem(at: part)
                                    guard fm.createFile(atPath: part.path, contents: Data()) else {
                                        throw CocoaError(.fileWriteUnknown)
                                    }
                                    completedBytes -= offset
                                    offset = 0
                                }
                                guard Int64(data.count) == file.bytes else {
                                    throw FluxModelError.downloadFailed(file.path)
                                }
                            case 416:
                                guard offset > 0 else {
                                    throw FluxModelError.downloadFailed(file.path)
                                }
                                try? fm.removeItem(at: part)
                                guard fm.createFile(atPath: part.path, contents: Data()) else {
                                    throw CocoaError(.fileWriteUnknown)
                                }
                                completedBytes -= offset
                                offset = 0
                                continue
                            default:
                                throw FluxModelError.downloadFailed(file.path)
                            }
                            guard !data.isEmpty, Int64(data.count) <= file.bytes - offset else {
                                throw FluxModelError.downloadFailed(file.path)
                            }
                            try Self.append(data, to: part)
                            offset += Int64(data.count)
                            completedBytes += Int64(data.count)
                            downloadedThisRun += Int64(data.count)
                            let elapsed = max(0.001, Date().timeIntervalSince(startedAt ?? Date()))
                            bytesPerSecond = Double(downloadedThisRun) / elapsed
                        }
                        guard offset == file.bytes else { throw FluxModelError.downloadFailed(file.path) }
                        guard try Self.hash(part) == file.sha256 else {
                            try? fm.removeItem(at: part)
                            completedBytes -= offset
                            offset = 0
                            throw FluxModelError.invalidFile(file.path)
                        }
                        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                        try fm.moveItem(at: part, to: final)
                        completed = true
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw error
                    } catch {
                        lastError = error
                        offset = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        if attempt < 2 {
                            try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 5))
                        }
                    }
                }
                if !completed { throw lastError ?? FluxModelError.downloadFailed(file.path) }
            }
            try Task.checkCancellation()
            guard runToken == token else { return }
            writeReadyMarker(manifest)
            completedBytes = manifest.totalBytes
            currentFile = ""
            status = .ready
            task = nil
        } catch is CancellationError {
            guard runToken == token else { return }
            status = .paused
            task = nil
        } catch let error as URLError where error.code == .cancelled {
            guard runToken == token else { return }
            status = .paused
            task = nil
        } catch {
            guard runToken == token else { return }
            status = .failed
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = currentFile.isEmpty
                ? "模型下载未完成：\(reason)"
                : "下载 \(currentFile) 失败：\(reason)。已完成的文件会保留。"
            task = nil
        }
    }

    private nonisolated static func contentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(String(bounds[0])),
              let end = Int64(String(bounds[1])),
              end >= start else { return nil }
        let total = parts[1] == "*" ? nil : Int64(String(parts[1]))
        return (start, end, total)
    }

    private nonisolated static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func writeReadyMarker(_ manifest: FluxModelManifest) {
        let value: [String: Any] = [
            "revision": manifest.revision,
            "repoID": manifest.repoID,
            "totalBytes": manifest.totalBytes,
            "files": manifest.files.count,
            "verifiedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        }
    }

    private func hasDiskSpace(for manifest: FluxModelManifest) -> Bool {
        let values = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= manifest.totalBytes - completedBytes + 2_000_000_000
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum FluxModelError: LocalizedError, Equatable {
    case invalidURL(String)
    case downloadFailed(String)
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path): return "无法构造下载地址：\(path)"
        case .downloadFailed(let path): return "下载未完成：\(path)。网络或服务器可能中断，已完成文件会保留。"
        case .invalidFile(let path): return "校验失败：\(path)。请重试或重新下载该文件。"
        }
    }
}
