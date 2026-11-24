import AppKit
import Combine
import RAWMasterCore
import RAWMasterLibrary
import SwiftUI

struct LibraryOverview: Decodable {
    struct Project: Decodable { let project: ProjectRecord; let files: Int; let captures: Int; let kept: Int }
    let projects: [Project]
    let files: Int
    let captures: Int
    let kept: Int
    let sessions: Int
    let groups: Int
}

enum CatalogPanel: String, Identifiable {
    case package, organization, migration, inspection, managedFiles, groupProcessing, discovery
    var id: Self { self }
}

@MainActor
final class ApplicationLibrarySession: ObservableObject {
    @Published private(set) var model: AppModel
    private var observation: AnyCancellable?
    init() {
        model = AppModel(usesPagedLibrary: true)
        observe()
    }
    private func observe() {
        model.activateLibrary = { [weak self] url in try self?.open(url) }
        observation = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    private func open(_ url: URL) throws {
        guard model.canSwitchLibrary else { throw LibraryEngineError("请等待当前资料库作业完成") }
        let next = AppModel(libraryURL: url, usesPagedLibrary: true)
        guard next.store != nil else { throw LibraryEngineError(next.errorMessage ?? "无法打开资料库") }
        try LibraryLocation.remember(url, defaults: .standard)
        try next.keepSelectedLibraryLocation()
        model.flushProjectReviewState()
        model.stopLibraryIndexing()
        model.editing?.leaveBrowsingContext()
        model.catalogGrid?.cancel()
        let previous = model
        Task {
            await previous.stopWorkbenchPhotoDelivery()
            await previous.editing?.shutdown(finishPreviews:false)
            await previous.editingServices?.shutdown()
        }
        model = next
        observe()
    }
}

extension AppModel {
    func openGroupProcessing(_ groupID: String) {
        processingGroupID = groupID
        libraryPanel = .groupProcessing
    }
    func inspectWorks(_ ids: [String]? = nil) {
        do {
            inspectionWorkIDs = try ids ?? store?.catalogFiles(for: actionAssetIDs.isEmpty ? focusedID.map { [$0] } ?? [] : actionAssetIDs).map { "file:" + $0.id } ?? []
            libraryPanel = .inspection
        } catch { errorMessage = error.localizedDescription }
    }
}

struct CatalogWorkspacePanel: View {
    @State private var inspectionGeneration = 0
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let panel: CatalogPanel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            switch panel {
            case .package:
                LibraryPackagePanel(catalog: model.libraryURL, canSwitch: { model.canSwitchLibrary }) { url in
                    guard let activate = model.activateLibrary else { throw LibraryEngineError("当前窗口无法切换资料库") }
                    try activate(url)
                }
            case .organization:
                if let actions = model.catalogActions {
                    LibraryOrganizationBrowser(actions: actions, onOpenWork: { model.inspectWorks([$0]) })
                }
            case .migration:
                if let actions = model.catalogActions {
                    LightroomMigrationPanel(actions: actions) { url in
                        guard let store = model.store else { throw LibraryEngineError("资料库已关闭") }
                        let project = model.currentProjectID
                        return try await Task.detached(priority: .userInitiated) {
                            try store.admitLightroomOriginal(url, projectID: project)
                        }.value
                    }
                }
            case .inspection:
                if let actions = model.catalogActions {
                    let receipt = LibraryBackupReceipt.latest(for: model.libraryURL)
                    if model.inspectionWorkIDs.count == 1, let first = model.inspectionWorkIDs.first {
                        CatalogWorkMediaView(workID:first,actions:actions,didEdit:{ inspectionGeneration += 1 })
                    }
                    LibraryInspectionPanel(actions: actions, workIDs: model.inspectionWorkIDs, groupID: model.activeGroup?.id,
                                           knownPackage: receipt?.package, knownManifestSHA256: receipt?.manifestSHA256, preview: { await CatalogWorkMedia.preview(for:$0,actions:actions) })
                        .id(inspectionGeneration)
                }
            case .discovery:
                if let actions = model.catalogActions {
                    let scope: [String:CatalogJSON] = model.scope == .project ? ["projectID": .string(model.scopeID)] : [:]
                    LibraryDiscoveryBrowser(actions:actions,scope:scope,onOpenWork:{ model.inspectWorks([$0]) })
                }
            case .groupProcessing:
                if let actions = model.catalogActions, let groupID = model.processingGroupID {
                    GroupProcessingPanel(actions: actions, groupID: groupID, render: LibraryGroupRendering.render)
                }
            case .managedFiles:
                if let actions = model.catalogActions, let store = model.store {
                    LibraryFileMovePanel(actions: actions, selection: (try? store.catalogFiles(for: model.actionAssetIDs)) ?? [],
                                         didMove: { model.reload() })
                }
            }
        }.padding(18).frame(minWidth: 740, minHeight: 515)
    }
}

private struct LibraryGridPaintContext: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var libraryGridCard: String? {
        get { self[LibraryGridPaintContext.self] }
        set { self[LibraryGridPaintContext.self] = newValue }
    }
}

extension AppModel {
    @ViewBuilder func paintMark(_ card: String?, photo: Bool = false) -> some View {
        if isPagedGrid, let grid = catalogGrid, grid.watermark != nil, let recorder = gridPaint {
            CatalogGridPaintMark(start: grid.firstPageStartedAt, cardID: card, photo: photo, recorder: recorder)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
