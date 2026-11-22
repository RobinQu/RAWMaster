import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct ExportWorkspace:View{
    @EnvironmentObject var model:AppModel
    @State private var format=PhotoRenderFormat.jpeg8
    @State private var preset=2048
    @State private var customLongEdge=3000
    @State private var quality=0.9
    @State private var directory=FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask)[0].appendingPathComponent("RAWMaster Exports",isDirectory:true)
    @State private var naming="{name}-{index}"
    @State private var running=false
    @State private var completed=0
    @State private var currentName=""
    @State private var results:[URL]=[]
    @State private var error:String?
    @State private var task:Task<Void,Never>?
    private var assets:[AssetRecord]{
        let ids=model.workbenchExportContext.exactAssetIDs.map(Set.init)
        return model.scopedAssets.filter{(ids?.contains($0.id) ?? true) && $0.availability == .available}
    }
    var body:some View{
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:0){
                VStack(alignment:.leading,spacing:5){
                    Text("导出工作台").font(.system(size:22,weight:.semibold))
                    Text("\(assets.count) 张照片 · 使用各自当前调整").foregroundStyle(.secondary).font(.caption)
                }.padding(22)
                Divider()
                List(assets){asset in
                    HStack(spacing:10){Image(systemName:CaptureFileFormat.isRAW(asset.filename) ? "camera.aperture":"photo").foregroundStyle(.secondary)
                        VStack(alignment:.leading){Text(asset.filename).lineLimit(1);Text(asset.projectName).font(.caption2).foregroundStyle(.secondary)}
                    }
                }.listStyle(.plain)
            }.frame(minWidth:300,idealWidth:380,maxWidth:480)
            Divider()
            ScrollView{
                VStack(alignment:.leading,spacing:22){
                    group("输出格式与尺寸"){
                        Picker("格式",selection:$format){Text("JPEG").tag(PhotoRenderFormat.jpeg8);Text("TIFF 16 位").tag(PhotoRenderFormat.tiff16);Text("PNG 16 位").tag(PhotoRenderFormat.png16)}.pickerStyle(.segmented)
                        Picker("分辨率预设",selection:$preset){Text("原始尺寸").tag(0);Text("社交媒体 · 1080").tag(1080);Text("网络分享 · 2048").tag(2048);Text("高质量 · 4096").tag(4096);Text("自定长边").tag(-1)}
                        if preset == -1{Stepper("长边 \(customLongEdge) 像素",value:$customLongEdge,in:64...100000)}
                        Text("仅缩小，不放大；保留原始宽高比与 sRGB ICC。").font(.caption).foregroundStyle(.secondary)
                        if format == .jpeg8{
                            HStack{Text("JPEG 质量");Slider(value:$quality,in:0.05...1);Text("\(Int((quality*100).rounded()))%").monospacedDigit().frame(width:42)}
                        }
                    }
                    group("输出位置"){
                        HStack{Text(directory.path).lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading);Button("选择…",action:chooseDirectory)}
                    }
                    group("文件命名"){
                        TextField("命名模板",text:$naming).textFieldStyle(.roundedBorder)
                        Text("支持 {name} 原文件名、{index} 序号、{date} 日期。同名文件自动追加序号，绝不覆盖。").font(.caption).foregroundStyle(.secondary)
                    }
                    if running{ProgressView(value:Double(completed),total:Double(max(1,assets.count))){Text("正在导出 \(completed)/\(assets.count)")};Text(currentName).font(.caption).foregroundStyle(.secondary)}
                    if let error{Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(AppPalette.warning).font(.caption).textSelection(.enabled)}
                    if !results.isEmpty{Label("已完成 \(results.count) 张照片",systemImage:"checkmark.circle.fill").foregroundStyle(AppPalette.keep)
                        Button("在 Finder 中显示"){NSWorkspace.shared.activateFileViewerSelecting(results)}}
                    HStack{Spacer();if running{Button("取消"){task?.cancel()}}else{Button("导出 \(assets.count) 张照片",action:start).buttonStyle(.borderedProminent).disabled(assets.isEmpty).accessibilityIdentifier("export.workspace.confirm")}}
                }.padding(30).frame(maxWidth:700).frame(maxWidth:.infinity)
            }.background(AppPalette.canvas)
        }.background(AppPalette.panel).onDisappear{if running{task?.cancel()}}
    }
    private func group<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View{VStack(alignment:.leading,spacing:12){Text(title).font(.headline);content()}}
    private func chooseDirectory(){let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.directoryURL=directory;if panel.runModal() == .OK,let url=panel.url{directory=url}}
    private func start(){
        running=true;completed=0;results=[];error=nil
        let configuration=PhotoBatchExportConfiguration(format:format,maximumLongEdge:preset == 0 ? nil:preset == -1 ? customLongEdge:preset,jpegQuality:quality)
        let destination=directory,template=naming
        task=Task{[model]in
            do{results=try await model.exportWorkbenchPhotos(directory:destination,namingTemplate:template,configuration:configuration){done,total,name in
                Task{@MainActor in completed=done;currentName=name}
            }}catch{self.error=Task.isCancelled || error is CancellationError ? "导出已取消；已完成的文件保留。":"导出未完成：\(error.localizedDescription)"}
            running=false;task=nil
        }
    }
}
