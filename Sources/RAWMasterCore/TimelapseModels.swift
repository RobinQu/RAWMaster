import Foundation

public enum TimelapseAspect: String, Codable, Sendable, CaseIterable {
    case landscape, portrait, square
    public var title: String {
        switch self { case .landscape: return "16:9 · 横屏"; case .portrait: return "9:16 · 竖屏"; case .square: return "1:1 · 方形" }
    }
}
public enum TimelapseResolution: String, Codable, Sendable, CaseIterable {
    case hd, uhd
    public var title: String { self == .hd ? "1080p" : "4K" }
    public var longEdge: Int { self == .hd ? 1920 : 3840 }
}
public enum TimelapseCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc
    public var title: String { self == .h264 ? "H.264 · 兼容优先" : "HEVC · 体积优先" }
}
public enum TimelapseAlignment: String, Codable, Sendable, CaseIterable {
    case off, stabilize, subject
    public var title: String {
        switch self { case .off: return "关闭"; case .stabilize: return "自动稳定（平移）"; case .subject: return "主体锚定（平移）" }
    }
}

/// Normalized rectangle in the oriented image. Origin is bottom-left, matching Core Image/Vision.
public struct TimelapseRegion: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0
            && width >= 0.1 && height >= 0.1 && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct TimelapseKeyframe: Codable, Sendable, Equatable, Identifiable {
    public var position: Double
    public var exposureEV: Double
    public var id: Double { position }
    public init(position: Double, exposureEV: Double = 0) { self.position = position; self.exposureEV = exposureEV }
}

public struct TimelapseSettings: Codable, Sendable, Equatable {
    public var aspect: TimelapseAspect = .landscape
    public var resolution: TimelapseResolution = .hd
    public var frameRate: Int = 30
    public var frameStride: Int = 1
    public var codec: TimelapseCodec = .h264
    public var deflickerStrength: Double = 0.6
    public var smoothingRadius: Int = 5
    public var alignment: TimelapseAlignment = .stabilize
    /// Maximum fraction removed from EACH edge for translation stabilization, additional to aspect crop.
    public var maxCropFraction: Double = 0.08
    public var subjectRegion: TimelapseRegion?
    public var keyframes: [TimelapseKeyframe] = []
    public init() {}

    public func validate(inputCount: Int) throws {
        guard inputCount >= 2, inputCount <= 100_000 else { throw LibraryError.invalid("合成需要 2–100000 张参与序列的照片。") }
        guard [24, 25, 30].contains(frameRate), [1, 2, 4].contains(frameStride),
              deflickerStrength.isFinite, (0...1).contains(deflickerStrength),
              (1...60).contains(smoothingRadius), maxCropFraction.isFinite,
              (0...0.2).contains(maxCropFraction) else { throw LibraryError.invalid("延时合成参数超出有效范围。") }
        guard outputFrameIndices(inputCount: inputCount).count >= 2 else { throw LibraryError.invalid("当前速度下不足两帧，请降低播放速度或增加照片。") }
        if alignment == .subject, subjectRegion?.isValid != true { throw LibraryError.invalid("请先在预览图中指定主体参考区域。") }
        if let subjectRegion, !subjectRegion.isValid { throw LibraryError.invalid("主体参考区域无效。") }
        guard keyframes.count <= 1000,
              keyframes.allSatisfy({ $0.position.isFinite && (0...1).contains($0.position)
                  && $0.exposureEV.isFinite && (-4...4).contains($0.exposureEV) }),
              Set(keyframes.map(\.position)).count == keyframes.count else { throw LibraryError.invalid("曝光关键帧必须具有唯一位置，补偿范围为 ±4 EV。") }
    }

    public func outputFrameIndices(inputCount: Int) -> [Int] {
        guard inputCount > 0, [1, 2, 4].contains(frameStride) else { return [] }
        return Array(stride(from: 0, to: inputCount, by: frameStride))
    }
    public func duration(inputCount: Int) -> Double {
        guard frameRate > 0 else { return 0 }
        return Double(outputFrameIndices(inputCount: inputCount).count) / Double(frameRate)
    }
    public func dimensions(preview: Bool = false) -> (width: Int, height: Int) {
        let edge = preview ? 960 : resolution.longEdge
        switch aspect {
        case .landscape: return (edge, edge * 9 / 16)
        case .portrait: return (edge * 9 / 16, edge)
        case .square: return (edge, edge)
        }
    }
    public func exposure(at position: Double) -> Double {
        let ordered = keyframes.sorted { $0.position < $1.position }
        guard let first = ordered.first, let last = ordered.last else { return 0 }
        if position <= first.position { return first.exposureEV }
        if position >= last.position { return last.exposureEV }
        for index in 1..<ordered.count where position <= ordered[index].position {
            let a = ordered[index - 1], b = ordered[index]
            let fraction = (position - a.position) / (b.position - a.position)
            // Smoothstep avoids abrupt changes in exposure slope at a keyframe.
            let eased = fraction * fraction * (3 - 2 * fraction)
            return a.exposureEV + (b.exposureEV - a.exposureEV) * eased
        }
        return last.exposureEV
    }
}

/// Stable composition scope. Assets are values; browsing or changing a filter cannot alter this input.
public struct TimelapseInput: Sendable {
    public let groupID: String, groupName: String
    public let groupRevision: Int
    public let assets: [AssetRecord]
    public let sourceFileCount: Int

    public static func make(group: CaptureGroup, eligibleAssets: [AssetRecord], pairs: [CapturePair] = []) throws -> TimelapseInput {
        guard Set(group.assetIDs).count == group.assetIDs.count else { throw LibraryError.invalid("组内存在重复成员，请先修复组顺序。") }
        let included = Set(group.includedAssetIDs)
        guard included.isSubset(of: Set(group.assetIDs)) else { throw LibraryError.invalid("序列参与状态与组成员不一致，请重新打开拍摄组。") }
        var lookup: [String: AssetRecord] = [:]
        for asset in eligibleAssets where asset.projectID == group.projectID { lookup[asset.id] = asset }
        let participating = group.assetIDs.filter { included.contains($0) }
        for id in participating where lookup[id] == nil { throw LibraryError.invalid("参与序列的成员未纳入当前项目或已不存在：\(id)") }
        var pairedRaw: [String: String] = [:]
        for pair in pairs where included.contains(pair.rawAssetID) && included.contains(pair.jpegAssetID) {
            guard let raw = lookup[pair.rawAssetID], let jpeg = lookup[pair.jpegAssetID],
                  raw.sessionID == pair.sessionID, jpeg.sessionID == pair.sessionID,
                  CaptureFileFormat.isRAW(raw.filename), CaptureFileFormat.isJPEG(jpeg.filename) else { continue }
            guard pairedRaw[pair.rawAssetID] == nil, pairedRaw[pair.jpegAssetID] == nil else { throw LibraryError.invalid("序列双格式关联冲突，请先复核 RAW+JPEG 关联。") }
            pairedRaw[pair.rawAssetID] = pair.rawAssetID; pairedRaw[pair.jpegAssetID] = pair.rawAssetID
        }
        var emitted = Set<String>(), frames: [AssetRecord] = []
        for id in participating {
            let chosen = pairedRaw[id] ?? id
            guard emitted.insert(chosen).inserted, let asset = lookup[chosen] else { continue }
            guard asset.availability == .available, asset.importState == .ready else { throw LibraryError.invalid("序列原片不可用：\(asset.filename)。请先重新定位或完成接入。") }
            frames.append(asset)
        }
        guard frames.count >= 2 else { throw LibraryError.invalid("至少需要两次参与序列的拍摄；已关联的 RAW+JPEG 只计一次。") }
        return TimelapseInput(groupID: group.id, groupName: group.name, groupRevision: group.groupRevision,
                              assets: frames, sourceFileCount: participating.count)
    }
}

public struct TimelapseProgress: Sendable {
    public enum Phase: String, Sendable { case analyzing, rendering, finishing
        public var title: String { switch self { case .analyzing: return "分析光照与画面"; case .rendering: return "合成视频"; case .finishing: return "完成编码" } }
    }
    public let phase: Phase
    public let completed: Int, total: Int
    public init(phase: Phase, completed: Int, total: Int) { self.phase = phase; self.completed = completed; self.total = total }
}

public struct TimelapseRenderResult: Sendable {
    public let outputURL: URL
    public let frameCount: Int, width: Int, height: Int
    public let duration: Double
    public let warnings: [String]
    public let cropFraction: Double
    public init(outputURL: URL, frameCount: Int, width: Int, height: Int, duration: Double, warnings: [String], cropFraction: Double) {
        self.outputURL = outputURL; self.frameCount = frameCount; self.width = width; self.height = height
        self.duration = duration; self.warnings = warnings; self.cropFraction = cropFraction
    }
}
