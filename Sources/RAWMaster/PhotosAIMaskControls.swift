import AppKit
import RAWMasterCore
import RAWMasterImaging
import SwiftUI

struct PhotosAIMaskControls: View {
  @ObservedObject var input: EditingMaskInputSession
  @ObservedObject var session: EditingDevelopmentSession
  let context: EditingInteractionContext
  let addRange: () -> Void
  @State private var creating = false
  private var tools: [DevelopmentSemanticTarget] {
    var targets: [DevelopmentSemanticTarget] = [.subject, .background, .instance, .brush]
    if input.modelStates[.object] == .verified { targets.append(.object) }
    if input.modelStates[.landscape] == .verified { targets += [.sky, .water] }
    return targets
  }
  var body: some View {
    VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
      Button { creating.toggle() } label: {
        HStack(spacing: 6) {
          Image(systemName: creating ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
          Label("新建蒙版", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
        }
      }.buttonStyle(PhotosFlatButtonStyle(stretches: true))
        .disabled(input.isActive || !input.allowsInput(context))
        .accessibilityLabel("新建蒙版").accessibilityValue(creating ? "已展开" : "已收起")
        .accessibilityIdentifier("photos.mask.create")
      if creating {
        VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
          Text("自动与画笔").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
            ForEach(tools, id: \.self) { target in
              Button { creating = false; input.begin(target, context: context) } label: {
                HStack(spacing: 6) {
                  PhotosMaskToolIcon(kind: .init(target: target))
                  Text(target.title).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 32)
              }.accessibilityLabel(target.title)
                .accessibilityIdentifier("photos.mask." + target.rawValue)
            }
          }.buttonStyle(PhotosFlatButtonStyle(stretches: true))
          Text("几何与范围").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, PhotosControlLayout.groupSpacing - PhotosControlLayout.descriptionSpacing)
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
            geometryTool("线性渐变", icon: .linear) { input.select(.linear, context: context) }
              .accessibilityIdentifier("photos.mask.linear")
            geometryTool("径向渐变", icon: .radial) { input.select(.radial, context: context) }
              .accessibilityIdentifier("photos.mask.radial")
            geometryTool("亮度范围", icon: .range, action: addRange)
              .accessibilityIdentifier("photos.mask.range")
          }.buttonStyle(PhotosFlatButtonStyle(stretches: true))
          Menu("管理模型包") {
            Button(input.modelStates[.landscape] == .damaged ? "修复天空与水面模型…" : "安装天空与水面模型…") {
              install(.landscape)
            }
            Button(input.modelStates[.object] == .damaged ? "修复物体选择模型…" : "安装物体选择模型…") {
              install(.object)
            }
          }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.top, 2).padding(.bottom, 4)
          .disabled(input.isActive || !input.allowsInput(context))
      }
      if !input.allowsInput(context) {
        Text("当前画布不可用于创建或修正蒙版。").foregroundStyle(.secondary)
      }
      if let kind = input.activeKind {
        HStack {
          Text("在照片上拖动以绘制\(kind.title)蒙版，或按 Escape 取消。")
          Spacer(minLength: 4)
          Button { input.cancel() } label: { Label("取消", systemImage: "xmark") }.buttonStyle(PhotosFlatButtonStyle())
        }.accessibilityElement(children: .contain).accessibilityIdentifier("photos.mask.drawing")
      }
      if input.modelStates.values.contains(.damaged) {
        Text("部分模型文件不完整或已损坏。请在「模型包」中选择修复。").foregroundStyle(.secondary)
      }
      if input.busy {
        HStack {
          ProgressView().controlSize(.mini)
          Text("正在本机处理…")
          Spacer()
          Button { input.cancel() } label: { Label("取消", systemImage: "xmark") }
        }
      }
      if let target = input.selecting, !input.busy {
        if target == .instance, !input.instanceOptions.isEmpty {
          Menu("按实例选择（" + String(input.instanceOptions.count) + "）") {
            ForEach(input.instanceOptions) { option in
              let position =
                option.point.x < 0.33 ? "原片左侧" : option.point.x > 0.67 ? "原片右侧" : "原片中央"
              Button("实例 " + String(option.id) + " · " + position) {
                input.chooseInstance(option, context: context)
              }
            }
          }
        }
        HStack {
          Text(target == .instance ? "点选一个前景实例，或拖框选择框内的主要实例。" : "点在物体上，或拖框圈出这个物体。")
          Spacer()
          Button { input.cancel() } label: { Label("取消", systemImage: "xmark") }
        }
      }
      if let draft = input.candidate {
        Divider()
        Text(draft.target.title + "选区").fontWeight(.semibold)
        Toggle(isOn: $input.showsOverlay) { Label("显示蒙版叠加", systemImage: "square.on.square") }
          .toggleStyle(PhotosFlatCheckboxStyle())
        PhotosFlatTabs(title: "精修画笔", selection: Binding<EditingMaskInputSession.Brush?>(get: { input.brush }, set: {
          if let brush = $0 { input.setBrush(brush) }
        }), options: [.add, .subtract], label: { $0 == .add ? "添加画笔" : "减去画笔" },
          symbol: { $0 == .add ? "plus" : "minus" })
        if input.brush != nil {
          PhotosSliderRow(title: "笔径 %", value: .constant(input.brushDiameter * 100),
            range: 0.5...30, step: 0.5, digits: 1) { input.brushDiameter = $0 / 100 }
        }
        HStack {
          Button { input.adopt(context: context) } label: { Label("采用选区", systemImage: "checkmark") }
            .disabled(!input.canAdopt).accessibilityIdentifier("photos.mask.adopt")
          Button { input.cancel() } label: { Label("关闭", systemImage: "xmark") }
        }.buttonStyle(PhotosFlatButtonStyle(stretches: true))
      }
      if let note = input.note {
        Text(note).foregroundStyle(.secondary).accessibilityIdentifier("photos.mask.status")
      }
    }.font(.caption).controlSize(.small)
      .task {
        while !Task.isCancelled {
          await input.refreshModels()
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
      }
      .onChange(of: session.revision) { _, next in input.recipeRevisionChanged(next) }
  }
  private func geometryTool(_ title: String, icon: PhotosMaskToolIcon.Kind, action: @escaping () -> Void) -> some View {
    Button { creating = false; action() } label: {
      HStack(spacing: 6) {
        PhotosMaskToolIcon(kind: icon)
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 32)
    }.accessibilityLabel(title)
  }
  private func install(_ component: DevelopmentMaskModelPack.Component) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "选择包含 Models 与 ONNXRuntime 的离线模型包文件夹。"
    if panel.runModal() == .OK, let url = panel.url { input.install(component, folder: url) }
  }
}
