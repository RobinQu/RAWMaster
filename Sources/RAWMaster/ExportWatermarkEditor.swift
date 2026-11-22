import AppKit
import CoreImage
import SwiftUI
import RAWMasterImaging

extension BuiltinPhotoStyle {
    var exportTitle: String {
        switch self {
        case .plain: "净图"
        case .paper: "相纸展签"
        case .mist: "模糊留白"
        case .sign: "画内署名"
        case .split: "双栏参数卡"
        case .date: "日期戳"
        }
    }
}

struct ExportPreviewPhoto {
    let id = UUID()
    let assetID: String
    let original: Bool
    let image: CGImage
    let metadata: PhotoExportMetadata
}

private actor ExportPreviewRasterizer {
    static let shared = ExportPreviewRasterizer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func bitmap(photo: ExportPreviewPhoto, layout: PhotoExportLayout, maximum: Int) throws -> CGImage {
        try Task.checkCancellation()
        let frame = try layout.render(CIImage(cgImage: photo.image), metadata: photo.metadata, maximumLongEdge: maximum)
        try Task.checkCancellation()
        guard let result = context.createCGImage(frame, from: frame.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw DevelopmentError.unreadable
        }
        return result
    }
}

struct ExportStyledPhoto: View {
    let photo: ExportPreviewPhoto
    let layout: PhotoExportLayout
    let maximum: Int
    var sample = false
    @State private var rendered: CGImage?
    @State private var renderedRequest: Request?
    @State private var issue: String?

    private struct Request: Equatable {
        var id: UUID
        var layout: PhotoExportLayout
        var maximum: Int
    }

    var body: some View {
        let request = Request(id: photo.id, layout: layout, maximum: maximum)
        ZStack {
            if let rendered, renderedRequest == request {
                Image(decorative: rendered, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else if let issue {
                Label(issue, systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sample ? layout.style.exportTitle : "成片预览")
        .accessibilityValue(renderedRequest == request ? layout.style.exportTitle + "已显示" : (issue ?? "正在绘制"))
        .accessibilityIdentifier(sample ? "export.style.sample." + layout.style.rawValue : "export.style.preview")
        .task(id: request) {
            rendered = nil
            issue = nil
            do {
                let value = try await ExportPreviewRasterizer.shared.bitmap(photo: photo, layout: layout, maximum: maximum)
                if !Task.isCancelled { rendered = value; renderedRequest = request }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}

struct ExportWatermarkEditor: View {
    let photo: ExportPreviewPhoto
    let filename: String
    let previewMaximum: Int
    let onApply: (PhotoExportLayout) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PhotoExportLayout

    init(photo: ExportPreviewPhoto, filename: String, previewMaximum: Int, layout: PhotoExportLayout,
         onApply: @escaping (PhotoExportLayout) -> Void) {
        self.photo = photo
        self.filename = filename
        self.previewMaximum = previewMaximum
        self.onApply = onApply
        _draft = State(initialValue: layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("边框与水印").font(.title2.weight(.semibold))
                Spacer()
                Text(filename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    ExportStyleCards(photo: photo, layout: draft, compact: false, identifier: "export.style.") { style in
                        draft = ExportLayoutControls.choosing(style, for: draft)
                    }.padding(12)
                }.frame(width: 290)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("当前照片预览").font(.headline)
                    ExportStyledPhoto(photo: photo, layout: draft, maximum: previewMaximum)
                        .padding(12).background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .frame(minHeight: 200)
                        .accessibilityLabel("当前照片的边框与水印预览")
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ExportLayoutControls(draft: $draft).frame(width: 235)
            }
            Divider()
            HStack {
                if draft.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("尚未填写署名，署名卡显示「示例署名」。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export.style.cancel")
                Button("应用版式") { onApply(draft); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(ExportLayoutControls.issue(for: draft) != nil)
                    .accessibilityIdentifier("export.style.apply")
            }.padding(15)
        }.frame(width: 970, height: 545)
    }

}

struct ExportStyleCards: View {
    let photo: ExportPreviewPhoto
    let layout: PhotoExportLayout
    let compact: Bool
    let identifier: String
    let onChoose: (BuiltinPhotoStyle) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: compact ? 6 : 10) {
            ForEach(BuiltinPhotoStyle.allCases, id: \.rawValue) { style in
                let card = cardLayout(style)
                let selected = layout.style == style
                Button { onChoose(style) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ExportStyledPhoto(photo: photo, layout: card, maximum: compact ? 160 : 240, sample: true)
                            .frame(height: compact ? 46 : 70).padding(3)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        HStack(spacing: 2) {
                            Text(style.exportTitle).font(.caption.weight(.medium)).lineLimit(1)
                            if style == .sign, layout.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("示例").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selected { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
                        }
                    }.padding(compact ? 4 : 6)
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.28)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(style.exportTitle)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(identifier + style.rawValue)
            }
        }
    }

    private func cardLayout(_ style: BuiltinPhotoStyle) -> PhotoExportLayout {
        var card = ExportLayoutControls.choosing(style, for: layout)
        if card.resolvedAppearance.mark == "signature", card.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            card.signature = "示例署名"
        }
        return card
    }
}
