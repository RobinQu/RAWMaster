import AppKit
import RAWMasterCore
import RAWMasterImaging
import SwiftUI

struct PhotosAIMaskControls: View {
  @ObservedObject var input: EditingMaskInputSession
  @ObservedObject var session: EditingDevelopmentSession
  let context: EditingInteractionContext
  let selected: DevelopmentMaskLayerV3?
  private var tools: [DevelopmentSemanticTarget] {
    var targets: [DevelopmentSemanticTarget] = [.subject, .background, .instance, .brush]
    if input.modelStates[.object] == .verified { targets.append(.object) }
    if input.modelStates[.landscape] == .verified { targets += [.sky, .water] }
    return targets
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], alignment: .leading, spacing: 6) {
        ForEach(tools, id: \.self) { target in
          Button(target.title) { input.begin(target, context: context) }
            .disabled(input.busy)
            .accessibilityIdentifier("photos.mask." + target.rawValue)
        }
      }
      HStack {
        if let selected, selected.kind == .subject, input.candidate == nil {
          Button("查看与修正选区") { input.review(selected, context: context) }
        }
        Spacer()
        Menu("模型包") {
          Button(input.modelStates[.landscape] == .damaged ? "修复天空与水面模型…" : "安装天空与水面模型…") {
            install(.landscape)
          }
          Button(input.modelStates[.object] == .damaged ? "修复物体选择模型…" : "安装物体选择模型…") {
            install(.object)
          }
        }.menuStyle(.borderlessButton).fixedSize().disabled(input.busy)
      }
      if input.modelStates.values.contains(.damaged) {
        Text("部分模型文件不完整或已损坏。请在「模型包」中选择修复。").foregroundStyle(.secondary)
      }
      if input.busy {
        HStack {
          ProgressView().controlSize(.mini)
          Text("正在本机处理…")
          Spacer()
          Button("取消") { input.cancel() }
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
          Button("取消") { input.cancel() }
        }
      }
      if let draft = input.candidate {
        Divider()
        Text(draft.target.title + "选区").fontWeight(.semibold)
        Toggle("显示蒙版叠加", isOn: $input.showsOverlay).toggleStyle(.checkbox)
        HStack {
          Button("添加画笔") { input.setBrush(.add) }.foregroundStyle(
            input.brush == .add ? AppPalette.accent : Color.primary)
          Button("减去画笔") { input.setBrush(.subtract) }.foregroundStyle(
            input.brush == .subtract ? AppPalette.accent : Color.primary)
        }
        if input.brush != nil {
          HStack {
            Text("笔径")
            Slider(value: $input.brushDiameter, in: 0.005...0.3)
            Text(input.brushDiameter, format: .percent.precision(.fractionLength(1)))
              .monospacedDigit()
          }
        }
        HStack {
          Button("采用选区") { input.adopt(context: context) }.disabled(!input.canAdopt)
            .accessibilityIdentifier("photos.mask.adopt")
          Button("关闭") { input.cancel() }
        }
      }
      if let note = input.note {
        Text(note).foregroundStyle(.secondary).accessibilityIdentifier("photos.mask.status")
      }
    }.font(.caption).controlSize(.small)
      .disabled(!input.allowsInput(context))
      .task {
        while !Task.isCancelled {
          await input.refreshModels()
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
      }
      .onChange(of: session.revision) { _, next in input.recipeRevisionChanged(next) }
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
