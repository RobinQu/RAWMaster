import RAWMasterLibrary
import SwiftUI

struct CatalogWorkEditor: View {
  let edit: CatalogLocalEdit
  let actions: CatalogActions
  let saved: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var recipe: CatalogLocalRecipe
  @State private var selected: CatalogLocalEdit
  @State private var useOriginal = false
  @State private var imageGeneration = 0
  @State private var source: CGImage?
  @State private var preview: CGImage?
  @State private var issue: String?
  @State private var saving = false

  init(edit: CatalogLocalEdit, actions: CatalogActions, saved: @escaping () -> Void) {
    self.edit = edit
    self.actions = actions
    self.saved = saved
    _recipe = State(initialValue: edit.recipe)
    _selected = State(initialValue: edit)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("编辑本地版本").font(.title2)
      Text(edit.name).lineLimit(1)
      if edit.canStartFromOriginal {
        Picker("编辑起点", selection: $useOriginal) {
          Text("本作品的 Lightroom 历史预览").tag(false)
          Text("已核验的原始照片").tag(true)
        }.pickerStyle(.segmented).disabled(saving)
      } else {
        Text(edit.source?.kind == .historicalLook ? "编辑起点为本作品保存的 Lightroom 历史预览" : "编辑起点为已核验的原始照片")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 18) {
        ZStack {
          Color.black
          if let preview {
            Image(decorative: preview, scale: 1).resizable().scaledToFit()
          } else if issue == nil {
            ProgressView()
          }
        }.frame(minWidth: 380, minHeight: 275)
        VStack(alignment: .leading, spacing: 12) {
          slider("曝光", value: $recipe.exposureEV, range: -5...5, suffix: " EV")
          GroupBox("裁切范围") {
            VStack(alignment: .leading) {
              slider(
                "左边缘", value: $recipe.crop.left, range: 0...max(0.001, recipe.crop.right - 0.025))
              slider(
                "右边缘", value: $recipe.crop.right, range: min(0.999, recipe.crop.left + 0.025)...1)
              slider(
                "上边缘", value: $recipe.crop.top, range: 0...max(0.001, recipe.crop.bottom - 0.025))
              slider(
                "下边缘", value: $recipe.crop.bottom, range: min(0.999, recipe.crop.top + 0.025)...1)
            }.padding(4)
          }
          Button("复位曝光与裁切") { recipe = .init() }
        }.frame(width: 210)
      }
      if let issue { Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("保存为此作品的新版本") { save() }.keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("work.localEdit.save")
          .disabled(source == nil || saving || (edit.hasLocalVersion && recipe == edit.recipe))
      }
    }.padding(18).frame(minWidth: 720, minHeight: 440)
      .task(id: useOriginal) {
        source = nil
        preview = nil
        issue = nil
        do {
          let next =
            useOriginal
            ? try await CatalogLocalEditing.startingFromOriginal(edit, actions: actions) : edit
          let bitmap = try await CatalogLocalEditing.image(for: next)
          try Task.checkCancellation()
          selected = next
          source = bitmap
          imageGeneration += 1
        } catch is CancellationError {} catch { issue = error.localizedDescription }
      }
      .task(id: DrawKey(recipe: recipe, imageGeneration: imageGeneration)) {
        guard let source else { return }
        do {
          let value = recipe
          let bitmap = try await Task.detached(priority: .userInitiated) {
            try CatalogLocalEditing.render(source, recipe: value)
          }.value
          try Task.checkCancellation()
          preview = bitmap
          issue = nil
        } catch is CancellationError {} catch { issue = error.localizedDescription }
      }
      .interactiveDismissDisabled(saving)
  }
  private struct DrawKey: Equatable {
    let recipe: CatalogLocalRecipe
    let imageGeneration: Int
  }
  private func slider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = ""
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title)
        Spacer()
        Text(String(format: "%.2f", value.wrappedValue) + suffix).monospacedDigit()
      }.font(.caption)
      Slider(value: value, in: range).accessibilityLabel(title)
    }
  }
  private func save() {
    guard !saving else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        _ = try await CatalogLocalEditing.save(recipe, for: selected, actions: actions)
        saved()
        dismiss()
      } catch { issue = error.localizedDescription }
    }
  }
}
