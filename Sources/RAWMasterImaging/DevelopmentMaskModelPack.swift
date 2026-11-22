import Darwin
import Foundation
import MaskAI
import RAWMasterCore

/// Optional files are resolved from one explicit installation, never from a photo or a recipe.
public struct DevelopmentMaskModelPack: Sendable {
  public enum Component: String, CaseIterable, Sendable { case landscape, object }
  public enum State: Equatable, Sendable { case missing, verified, damaged }
  private static let integrity = MaskFileIntegrity()
  public let root: URL
  public init(root: URL) { self.root = root }
  public static var installed: Self {
    .init(
      root: URL.applicationSupportDirectory.appending(
        path: "RAWMaster/MaskAI/v1", directoryHint: .isDirectory))
  }
  public static let runtimePath = "ONNXRuntime/lib/libonnxruntime.1.27.0.dylib"
  public static let runtimeHash = "49422a138fff12d7fcbd544373aefbffd510e473e08e18af28a8ecc3581029bf"
  public static let landscapeHash =
    "bdbe3961a13d75fe259f4bbc5d93dc8e4b5fe130c599acd6009ae1f382d6bc5d"

  public func modelHashes(_ component: Component) -> [String] {
    switch component {
    case .landscape: [Self.landscapeHash]
    case .object:
      [MaskAIModel.slimSAMEncoder.expectedSHA256, MaskAIModel.slimSAMDecoder.expectedSHA256]
    }
  }
  private func files(_ component: Component) -> [(String, String)] {
    let models: [MaskAIModel] =
      component == .landscape ? [.efficientViT] : [.slimSAMEncoder, .slimSAMDecoder]
    return [(Self.runtimePath, Self.runtimeHash)]
      + zip(models, modelHashes(component)).map { ("Models/" + $0.0.relativePath, $0.1) }
  }
  /// Run on a background executor. An unchanged inode can reuse a prior SHA check.
  public func state(of component: Component) throws -> State {
    let required = files(component)
    let models = required.dropFirst()
    guard
      models.contains(where: {
        FileManager.default.fileExists(atPath: root.appending(path: $0.0).path)
      })
    else { return .missing }
    for (path, digest) in required {
      do {
        if try !Self.integrity.matches(root.appending(path: path), expected: digest) {
          return .damaged
        }
      } catch is CancellationError { throw CancellationError() } catch { return .damaged }
    }
    return .verified
  }
  public func contains(_ component: Component) -> Bool { (try? state(of: component)) == .verified }
  public func verify(_ component: Component) throws {
    switch try state(of: component) {
    case .verified: return
    case .missing: throw DevelopmentMaskError.missingModels
    case .damaged: throw DevelopmentMaskError.invalidModels
    }
  }

  public func install(_ component: Component, from folder: URL) async throws {
    try await install(component, from: folder, beforePublication: {})
  }
  func install(
    _ component: Component, from folder: URL,
    beforePublication: @escaping @Sendable () throws -> Void
  ) async throws {
    let admission = MaskInstallAdmission()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let worker = Task.detached(priority: .utility) {
        try installFiles(
          component, from: folder, admission: admission, beforePublication: beforePublication)
      }
      try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
    } onCancel: {
      admission.cancel()
    }
  }

  private func installFiles(
    _ component: Component, from folder: URL, admission: MaskInstallAdmission,
    beforePublication: () throws -> Void
  ) throws {
    let incoming = DevelopmentMaskModelPack(root: folder)
    let fm = FileManager.default
    try Task.checkCancellation()
    try incoming.verify(component)
    let live = root.resolvingSymlinksInPath().standardizedFileURL
    if folder.resolvingSymlinksInPath().standardizedFileURL == live { return }
    let parent = live.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let lockName = "." + live.lastPathComponent + ".install.lock"
    let fd = Darwin.open(parent.appending(path: lockName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    defer { Darwin.close(fd) }
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
      try Task.checkCancellation()
      usleep(20_000)
    }
    try Task.checkCancellation()
    let stage = parent.appending(
      path: "." + live.lastPathComponent + "-" + UUID().uuidString, directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: stage) }
    let replacing = fm.fileExists(atPath: live.path)
    if replacing {
      try fm.copyItem(at: live, to: stage)
    } else {
      try fm.createDirectory(at: stage, withIntermediateDirectories: false)
    }
    for (path, _) in files(component) {
      try Task.checkCancellation()
      let dest = stage.appending(path: path)
      let directory = dest.deletingLastPathComponent()
      guard directory.resolvingSymlinksInPath().path.hasPrefix(stage.path + "/") else {
        throw DevelopmentMaskError.invalidModels
      }
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
      try fm.copyItem(at: folder.appending(path: path).resolvingSymlinksInPath(), to: dest)
    }
    try DevelopmentMaskModelPack(root: stage).verify(component)
    try beforePublication()
    try admission.publish {
      // APFS swaps complete generations. The former live tree is now at stage and is removed
      // by the defer. At every point readers see either a complete prior pack or the new pack.
      let result =
        replacing
        ? renamex_np(stage.path, live.path, UInt32(RENAME_SWAP))
        : Darwin.rename(stage.path, live.path)
      guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
  }
}

private final class MaskInstallAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  func publish(_ block: () throws -> Void) throws {
    try lock.withLock {
      guard !cancelled, !Task.isCancelled else { throw CancellationError() }
      try block()
    }
  }
}

private final class MaskFileIntegrity: @unchecked Sendable {
  private struct Identity: Equatable {
    let device: dev_t, inode: ino_t, size: off_t
    let changedSeconds, changedNanos, modifiedSeconds, modifiedNanos: Int
    init(_ url: URL) throws {
      var info = stat()
      guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        throw DevelopmentMaskError.invalidModels
      }
      device = info.st_dev
      inode = info.st_ino
      size = info.st_size
      changedSeconds = info.st_ctimespec.tv_sec
      changedNanos = info.st_ctimespec.tv_nsec
      modifiedSeconds = info.st_mtimespec.tv_sec
      modifiedNanos = info.st_mtimespec.tv_nsec
    }
  }
  private struct CheckedFile {
    let id: Identity
    let digest: String
  }
  private let lock = NSLock()
  private var checked: [URL: CheckedFile] = [:]
  func matches(_ url: URL, expected: String) throws -> Bool {
    try Task.checkCancellation()
    let identity = try Identity(url)
    if let prior = lock.withLock({ checked[url] }), prior.id == identity {
      return prior.digest == expected
    }
    let digest = try RenderFiles.hash(url)
    guard try Identity(url) == identity else { return false }
    lock.withLock {
      if checked.count >= 64 { checked.removeAll(keepingCapacity: true) }
      checked[url] = .init(id: identity, digest: digest)
    }
    return digest == expected
  }
}

public enum DevelopmentMaskError: LocalizedError {
  case missingModels, invalidModels, absent, staleSource, invalidPrompt, noImage
  public var errorDescription: String? {
    switch self {
    case .missingModels: "尚未安装相应的本机模型包。可用前景实例或画笔选择范围。"
    case .invalidModels: "模型包校验失败。请使用指定版本的运行库和权重。"
    case .absent: "未找到足够明确的选区。请重新点选、框选，或改用画笔。"
    case .staleSource: "原片内容或方向已改变，请重新打开照片。"
    case .invalidPrompt: "请在照片内点选目标，或框住一个物体。"
    case .noImage: "无法读取这张照片的分析图。"
    }
  }
}
