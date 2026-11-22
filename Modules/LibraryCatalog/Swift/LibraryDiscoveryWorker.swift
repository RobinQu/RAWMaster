#if os(macOS)
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct DiscoveryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct DiscoverySource: Decodable {
    let path: String?
    let sha256: String?
    let bytes: Int64?
    let location: String
    let kind: String
    let mediaKind:String?
    let filename: String
    let proxySHA256: String?
}

private struct DiscoveryModelManifest: Decodable {
    struct FaceEncoder: Decodable { let file: String }
    let faceEncoder: FaceEncoder
}

/// Independent libraries own their own queue and consent. No remote runtime is involved.
public actor LibraryDiscoveryWorker {
    private let runtime: URL?
    private let models: URL?
    private var process: Process?
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var pendingBytes = Data()

    public init(runtime: URL? = nil, models: URL? = nil) {
        self.runtime = runtime
        self.models = models
    }
    private func paths() throws -> (URL, URL, URL) {
        let fm = FileManager.default
        let bundle = Bundle.main.resourceURL?.appendingPathComponent("LibraryDiscovery")
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RAWMaster/LibraryDiscovery")
        let defaults = [bundle, support].compactMap { $0 }
        let root = defaults.first { fm.isExecutableFile(atPath: $0.appendingPathComponent("runtime/bin/python3.12").path) }
        var executable = runtime ?? root?.appendingPathComponent("runtime/bin/python3.12")
        if let path = executable {
            var directory: ObjCBool = false
            if fm.fileExists(atPath: path.path, isDirectory: &directory), directory.boolValue {
                let direct = path.appendingPathComponent("bin/python3.12")
                executable = fm.isExecutableFile(atPath: direct.path) ? direct : path.appendingPathComponent("runtime/bin/python3.12")
            }
        }
        guard let binary = executable, fm.isExecutableFile(atPath: binary.path),
              let directory = models ?? root?.appendingPathComponent("models"),
              fm.fileExists(atPath: directory.appendingPathComponent("vision-f16w.onnx").path),
              let script = Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "discovery") else {
            throw DiscoveryError("本地模型包尚未安装。将 LibraryDiscovery 放入应用资源或 ~/Library/Application Support/RAWMaster。")
        }
        return (binary, directory, script)
    }
    private func hasFaceModel(in directory: URL) -> Bool {
        let resource = Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "discovery")
        guard let resource, let bytes = try? Data(contentsOf: resource),
              let pins = try? JSONDecoder().decode(DiscoveryModelManifest.self, from: bytes) else { return false }
        return FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(pins.faceEncoder.file).path)
    }

    public func available(kind: String? = nil) -> Bool {
        guard let (_, models, _) = try? paths() else { return false }
        return kind != "faces" || hasFaceModel(in: models)
    }

    public func close() {
        try? writer?.close()
        try? reader?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        writer = nil
        reader = nil
        pendingBytes.removeAll()
    }
    private func start() throws {
        if let process, process.isRunning { return }
        close()
        let (python, models, script) = try paths()
        let job = Process()
        let input = Pipe()
        let output = Pipe()
        job.executableURL = python
        job.arguments = ["-I", "-B", script.path, "--models", models.path]
        job.standardInput = input
        job.standardOutput = output
        job.standardError = FileHandle.nullDevice
        try job.run()
        self.process = job
        writer = input.fileHandleForWriting
        reader = output.fileHandleForReading
    }
    private func invoke(_ request: [String: CatalogJSON]) throws -> CatalogJSON {
        try start()
        guard let writer, let reader else { throw DiscoveryError("无法启动本机模型。") }
        var data = try JSONEncoder().encode(CatalogJSON.object(request))
        data.append(10)
        do {
            try writer.write(contentsOf: data)
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            var scratch = [UInt8](repeating: 0, count: 65536)
            while pendingBytes.firstIndex(of: 10) == nil {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw DiscoveryError("本机模型响应超时，可重新开始索引。") }
                var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 250)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw POSIXError(.EIO) }
                // FileHandle.read(upToCount:) can wait to fill a short pipe reply.
                let count = scratch.withUnsafeMutableBytes { bytes in Darwin.read(reader.fileDescriptor, bytes.baseAddress, bytes.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DiscoveryError("本机模型已退出，可重新开始索引。") }
                pendingBytes.append(contentsOf: scratch.prefix(count))
                guard pendingBytes.count <= 16 * 1024 * 1024 else { throw DiscoveryError("模型输出超出限制。") }
            }
            let end = pendingBytes.firstIndex(of: 10)!
            let answer = try JSONDecoder().decode(CatalogJSON.self, from: pendingBytes[..<end])
            pendingBytes.removeSubrange(...end)
            guard answer["ok"] == .boolean(true), let result = answer["result"] else {
                throw DiscoveryError(answer["error"]?.stringValue ?? "本机模型处理失败。")
            }
            return result
        } catch {
            close()
            throw error
        }
    }
    public func text(_ text: String) throws -> CatalogJSON {
        try invoke(["version": .integer(1), "op": .string("text"), "text": .string(text)])
    }

    private func proxyCache(database: URL, sha: String) throws -> URL {
        guard sha.utf8.count == 64, sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DiscoveryError("代理摘要无效。")
        }
        let base = database.deletingLastPathComponent().resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("LibraryIndexes/discovery-proxies/" + String(sha.prefix(2)))
        guard dir.resolvingSymlinksInPath().standardizedFileURL == dir.standardizedFileURL else {
            throw DiscoveryError("代理目录包含无效链接。")
        }
        let target = dir.appendingPathComponent(sha + ".jpg")
        guard target.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else {
            throw DiscoveryError("代理位置包含无效链接。")
        }
        return target
    }
    private func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func retainProxy(_ url: URL, database: URL, sha: String) throws {
        let target = try proxyCache(database: database, sha: sha)
        if url == target { return }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 16 * 1024 * 1024, checksum(bytes) == sha else { throw DiscoveryError("代理核验失败。") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: target, options: .atomic)
    }
    private func proxy(_ descriptor: CatalogJSON, database: URL, dir: URL) async throws -> URL {
        let input = try descriptor.decoded(DiscoverySource.self)
        if let sha = input.proxySHA256 {
            let stored = try proxyCache(database: database, sha: sha)
            if let values = try? stored.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true, let n = values.fileSize, n <= 16 * 1024 * 1024,
               let data = try? Data(contentsOf: stored), checksum(data) == sha { return stored }
        }
        guard let path = input.path, let sha = input.sha256, let size = input.bytes, size >= 0 else {
            throw DiscoveryError("此作品暂时没有可核验的图像来源。")
        }
        let source: URL
        if input.location == "resource" {
            let root = database.deletingLastPathComponent().appendingPathComponent("LibraryResources").resolvingSymlinksInPath()
            let candidate = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/") else { throw DiscoveryError("作品资源路径无效。") }
            source = candidate
        } else {
            guard input.location == "original", path.hasPrefix("/") else { throw DiscoveryError("原片位置不可用。") }
            source = URL(fileURLWithPath: path)
        }
        let knownExtension = source.pathExtension.isEmpty ? URL(fileURLWithPath: input.filename).pathExtension : source.pathExtension
        let suffix = knownExtension.range(of: #"^[a-zA-Z0-9]{1,12}$"#, options: .regularExpression) == nil ? "" : knownExtension
        let copy = suffix.isEmpty ? dir.appendingPathComponent("input") : dir.appendingPathComponent("input").appendingPathExtension(suffix)
        guard FileManager.default.createFile(atPath: copy.path, contents: nil) else { throw DiscoveryError("无法暂存索引输入。") }
        let from = try FileHandle(forReadingFrom: source)
        let to = try FileHandle(forWritingTo: copy)
        defer { try? from.close(); try? to.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let block = try from.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            count += Int64(block.count)
            if count > size { throw DiscoveryError("文件已变化，请重新核验位置。") }
            digest.update(data: block)
            try to.write(contentsOf: block)
        }
        try to.synchronize()
        guard count == size, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha else {
            throw DiscoveryError("文件内容与当前作品版本不一致。")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024]
        let cg: CGImage
        if let imageSource = CGImageSourceCreateWithURL(copy as CFURL, nil),
           let frame = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
            cg = frame
        } else if input.mediaKind == "derivedVideo" || input.kind == "derivedVideo" {
            let snapshot = AVAssetImageGenerator(asset: AVURLAsset(url: copy, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]))
            snapshot.appliesPreferredTrackTransform = true
            snapshot.maximumSize = CGSize(width: 1024, height: 1024)
            cg = try await snapshot.image(at: .zero).image
        } else { throw DiscoveryError("无法从当前文件生成画面代理。") }
        let dest = dir.appendingPathComponent("proxy.jpg")
        guard let output = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DiscoveryError("无法创建代理。")
        }
        CGImageDestinationAddImage(output, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw DiscoveryError("代理写入失败。") }
        return dest
    }
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawmaster-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }
    public func preview(_ input: CatalogJSON, database: URL) async throws -> Data {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let picture = try await proxy(input, database: database, dir: dir)
        return try Data(contentsOf: picture)
    }
    /// Validate the current content outside the writer, then finish with its lease and input version.
    public func drain(actions: CatalogActions, kind: String? = nil) async throws -> Int {
        let (_, models, _) = try paths()
        let faceAvailable = hasFaceModel(in: models)
        if kind == "faces", !faceAvailable {
            throw DiscoveryError("本机人脸模型需要更新。")
        }
        let runnableKind = kind ?? (faceAvailable ? nil : "scene")
        var count = 0
        while !Task.isCancelled {
            var filter: [String: CatalogJSON] = ["leaseSeconds": .integer(300)]
            if let runnableKind { filter["kind"] = .string(runnableKind) }
            let next = try await actions.perform("discover.claim", filter)
            if next["job"] == .null {
                let pending = try await actions.read("discovery", ["op": .string("pending")])
                let due = pending["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if due.contains(where: { runnableKind == nil || $0 == runnableKind }) {
                    let sync = runnableKind.map { ["kind": CatalogJSON.string($0)] } ?? [:]
                    _ = try await actions.perform("discover.sync", sync)
                    continue
                }
                return count
            }
            guard let job = next["job"], let input = job["input"],
                  let type = job["kind"]?.stringValue, let id = job["jobID"], let lease = job["lease"],
                  let version = job["inputVersion"] else { return count }
            var fields: [String: CatalogJSON] = ["jobID": id, "lease": lease, "inputVersion": version]
            do {
                let dir = try temporary()
                defer { try? FileManager.default.removeItem(at: dir) }
                let proxy = try await proxy(input, database: actions.database, dir: dir)
                try Task.checkCancellation()
                let computed = try invoke(["version": .integer(1), "op": .string(type), "proxy": .string(proxy.path)])
                guard case let .object(result) = computed else { throw DiscoveryError("模型返回格式无效。") }
                if case .string(let sha) = result["proxySHA256"] {
                    try retainProxy(proxy, database: actions.database, sha: sha)
                }
                fields.merge(result) { _, new in new }
                let status = try await actions.perform("discover.finish", fields)
                if status["status"] == .string("done") { count += 1 }
            } catch is CancellationError {
                _ = try await actions.perform("discover.stop", ["jobID": id])
                throw CancellationError()
            } catch {
                _ = try await actions.perform("discover.fail", ["jobID": id, "lease": lease,
                    "error": .string(String(error.localizedDescription.prefix(2000)))])
            }
        }
        return count
    }
}
#endif
