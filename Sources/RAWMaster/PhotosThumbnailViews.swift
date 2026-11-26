import SwiftUI
import RAWMasterCore
import RAWMasterImaging

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct PhotosThumbnailVisibility: ViewModifier {
    let editing: EditingController
    let context: EditingInteractionContext
    let kind: DevelopmentThumbnailKind
    let viewportHeight: CGFloat
    @State private var lastRect: CGRect = .zero
    private func evaluate(_ rect: CGRect, height: CGFloat, reason: ThumbnailDiagnosticReason) {
        let finite = [rect.minX, rect.minY, rect.width, rect.height, height].allSatisfy(\.isFinite)
        let visible = finite && rect.width > 0 && rect.height > 0 && height > 0 && rect.maxY > 0 && rect.minY < height
        InteractionTrace.shared.thumbnail(.visibility, kind: kind) {
            .init(reason: reason, flags: [.finite: finite, .scopeMatch: editing.developmentContext == context, .computedVisible: visible],
                numbers: [.x: Double(rect.minX), .y: Double(rect.minY), .width: Double(rect.width),
                          .height: Double(rect.height), .viewportHeight: Double(height)])
        }
        editing.developmentThumbnails.setVisible(kind, visible, context: context)
    }
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named("photos.inspector.scroll"))
        } action: { rect in
            lastRect = rect; evaluate(rect, height: viewportHeight, reason: .rect)
        }.onChange(of: viewportHeight) { _, height in evaluate(lastRect, height: height, reason: .height) }
            .onChange(of: context) { _, _ in evaluate(lastRect, height: viewportHeight, reason: .context) }
            .onAppear { evaluate(lastRect, height: viewportHeight, reason: .appear) }
            .onDisappear {
                InteractionTrace.shared.thumbnail(.visibility, kind: kind) {
                    .init(reason: .disappear, flags: [.scopeMatch: editing.developmentContext == context, .computedVisible: false])
                }
                editing.developmentThumbnails.setVisible(kind, false, context: context)
            }
    }
}

/// The mounted image surface keeps its own input sequence even when its edit detaches the images.
struct PhotosThumbnailTracking {
    private(set) var active = false
    mutating func begin(hasImages: Bool) -> Bool {
        guard !active, hasImages else { return false }
        active = true; return true
    }
    mutating func end() -> Bool {
        guard active else { return false }
        active = false; return true
    }
}
struct PhotosThumbnailStrip: View {
    @ObservedObject var owner: EditingThumbnailPresentation
    let kind: DevelopmentThumbnailKind
    let value: Double
    let context: EditingInteractionContext
    let interaction: (Bool) -> Void
    let change: (Double) -> Void
    @State private var tracking = PhotosThumbnailTracking()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // This surface remains mounted through an image gesture's own invalidation.
                // Idle/status has a separate hit/AX subtree and cannot begin a summary edit.
                Group {
                    if let set = owner.sets[kind.presentationKey] {
                        HStack(spacing: 1) {
                            ForEach(Array(set.images.enumerated()), id: \.offset) { _, image in
                                Image(nsImage: image).resizable().scaledToFill().frame(width: max(1, (geometry.size.width - 4) / 5), height: 48).clipped()
                            }
                        }
                    } else { Color.clear }
                }.frame(width: geometry.size.width, height: 48).contentShape(Rectangle())
                    .allowsHitTesting(owner.sets[kind.presentationKey] != nil || tracking.active)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                        guard tracking.active || owner.sets[kind.presentationKey] != nil else { return }
                        if tracking.begin(hasImages: owner.sets[kind.presentationKey] != nil) { interaction(true) }
                        if geometry.size.width > 0 { change(min(1, max(-1, event.location.x / geometry.size.width * 2 - 1))) }
                    }.onEnded { _ in if tracking.end() { interaction(false) } })
                    .accessibilityElement(children: .ignore).accessibilityLabel("效果强度")
                    .accessibilityValue(DevelopmentNumericText.format(value, fractionDigits: 2))
                    .accessibilityHidden(owner.sets[kind.presentationKey] == nil)
                    .accessibilityAdjustableAction { direction in
                        guard owner.sets[kind.presentationKey] != nil else { return }
                        interaction(true)
                        change(min(1, max(-1, value + (direction == .increment ? 0.1 : -0.1))))
                        interaction(false)
                    }
                if owner.sets[kind.presentationKey] == nil && !tracking.active {
                    PhotosThumbnailStatus(owner: owner, kind: kind, context: context)
                }
            }.frame(width: geometry.size.width, height: 48)
        }.frame(height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
            .help("效果条为缩略图示意，请以主图为准。")
            .onDisappear { if tracking.end() { interaction(false) } }
    }
}
struct PhotosThumbnailStatus: View {
    @ObservedObject var owner: EditingThumbnailPresentation
    let kind: DevelopmentThumbnailKind
    let context: EditingInteractionContext
    var body: some View {
        HStack {
            if owner.state(kind).isBusy {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack { ProgressView().controlSize(.mini); Text(owner.progressText(kind)).font(.caption) }
                }
            } else if owner.state(kind) != .ready {
                Text(owner.errors[kind.presentationKey] ?? (owner.state(kind) == .waitingForSource
                    ? "等待当前照片预览完成。" : "效果预览尚未开始。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("重试预览") { owner.retry(kind, context: context) }.font(.caption)
                    .accessibilityIdentifier("photos.\(kind.presentationKey).thumbnail.retry")
            }
        }.frame(minHeight: 48)
    }
}

extension DevelopmentPhotoFilterV3 {
    var photosName: String {
        switch self {
        case .original: return "原片"
        case .vivid: return "鲜明"
        case .vividWarm: return "鲜明暖色"
        case .vividCool: return "鲜明冷色"
        case .dramatic: return "反差色"
        case .dramaticWarm: return "反差暖色"
        case .dramaticCool: return "反差冷色"
        case .mono: return "单色"
        case .silvertone: return "银色调"
        case .noir: return "黑白"
        case .spektraPortra400Endura, .spektraVelvia100, .spektraVision250D2383,
             .spektraGold200UltraEndura, .spektraPortra800SupraEndura, .spektraEktar100Endura,
             .spektraProvia100F, .spektraEktachrome100, .spektraVision500T2383:
            return spektrafilmTitle ?? rawValue
        }
    }
}
