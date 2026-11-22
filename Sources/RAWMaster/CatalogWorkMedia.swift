import AVKit
import ImageIO
import RAWMasterLibrary
import SwiftUI

struct CatalogWorkMedia: Decodable, Sendable {
  let path: String
  let sha256: String
  let kind: String
  let version: String
  let workVersionID: String?
  let resourceID: String
  let revisionBound: Bool
  let historicalGeneration: String?

  func videoAsset() -> AVURLAsset {
    AVURLAsset(
      url: URL(fileURLWithPath: path), options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
  }

  static func resolve(_ work: String, actions: CatalogActions) async -> Self? {
    try? await actions.read("lightroom", ["action": .string("workMedia"), "workID": .string(work)])
      .decoded(Self.self)
  }

  static func preview(for work: String, actions: CatalogActions) async -> LibraryInspectionPreview?
  {
    if let edit = try? await CatalogLocalEditing.open(work, actions: actions), edit.hasLocalVersion,
      let sample = try? await CatalogLocalPreviewCache.shared.sample(for: edit)
    {
      let c = edit.recipe.crop
      return LibraryInspectionPreview(
        sample: sample,
        crop: CGRect(x: c.left, y: c.top, width: c.right - c.left, height: c.bottom - c.top),
        sensorGeometryKnown: edit.source?.kind == .original)
    }
    guard let media = await resolve(work, actions: actions), media.kind != "derivedVideo" else {
      return nil
    }
    return LibraryInspectionPreview(
      sample: LibraryHistogramSource(
        kind: media.kind == "historical" ? .proxy : .render,
        url: URL(fileURLWithPath: media.path), sha256: media.sha256,
        versionID: media.workVersionID ?? media.version, sourceVersionID: media.version),
      sensorGeometryKnown: false)
  }
}

struct CatalogWorkMediaView: View {
  let workID: String
  let actions: CatalogActions
  @State private var media: CatalogWorkMedia?
  @State private var player: AVPlayer?
  @State private var local: CatalogLocalEdit?
  @State private var currentPhoto: CGImage?
  @State private var editing = false
  @State private var generation = 0
  @State private var issue: String?
  var didEdit: () -> Void = {}
  var body: some View {
    VStack(alignment: .leading) {
      if let currentPhoto {
        Image(decorative: currentPhoto, scale: 1).resizable().scaledToFit().frame(maxHeight: 220)
      }
      if let local, local.belongsToLightroom {
        HStack {
          if local.sourceURL != nil {
            Button(local.hasLocalVersion ? "继续编辑此作品的本地版本" : "为此作品创建本地编辑版本") { editing = true }
              .accessibilityIdentifier("work.localEdit.open")
          } else {
            Text("此版本的来源离线").foregroundStyle(.secondary)
          }
          if local.hasLocalVersion { Text("已保存本地曝光与裁切").font(.caption) }
        }
      }
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
      if let player { VideoPlayer(player: player).frame(minHeight: 220) }
      if let media {
        if media.kind == "historical" {
          if media.historicalGeneration == "previous" { Text("较早迁入的历史外观 · 当前迁入缺少预览") }
          Text(media.revisionBound ? "Lightroom 历史外观 · 已核对显影摘要" : "Lightroom 历史预览 · 缺少同版显影摘要")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Button("在访达显示成片") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: media.path)])
          }
        }
      }
    }
    .sheet(isPresented: $editing) {
      if let local {
        CatalogWorkEditor(edit: local, actions: actions) {
          generation += 1
          didEdit()
        }
      }
    }
    .task(id: LoadKey(work: workID, generation: generation)) {
      player?.pause()
      player = nil
      media = nil
      local = nil
      currentPhoto = nil
      issue = nil
      let current = await CatalogWorkMedia.resolve(workID, actions: actions)
      guard !Task.isCancelled else { return }
      media = current
      if let current, current.kind == "derivedVideo" {
        player = AVPlayer(playerItem: AVPlayerItem(asset: current.videoAsset()))
        return
      }
      do {
        let item = try await CatalogLocalEditing.open(workID, actions: actions)
        try Task.checkCancellation()
        guard item.belongsToLightroom else { return }
        local = item
        if item.sourceURL == nil, let history = item.historicalReferenceURL {
          let image = await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(history as CFURL, nil) else {
              return nil as CGImage?
            }
            return CGImageSourceCreateThumbnailAtIndex(
              src, 0,
              [
                kCGImageSourceThumbnailMaxPixelSize: 1000,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
          }.value
          try Task.checkCancellation()
          currentPhoto = image
        } else if item.sourceURL != nil {
          let input = try await CatalogLocalEditing.image(for: item, maxSize: 1000)
          let result = try await Task.detached(priority: .utility) {
            try CatalogLocalEditing.render(input, recipe: item.recipe)
          }.value
          try Task.checkCancellation()
          currentPhoto = result
        }
      } catch is CancellationError {} catch { issue = error.localizedDescription }
    }.onDisappear { player?.pause() }
  }
  private struct LoadKey: Equatable {
    let work: String
    let generation: Int
  }
}
