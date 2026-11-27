import Foundation
import RAWMasterCore
import RAWMasterImaging

enum VirtualCopyAction { case create, rename, remove }

struct VirtualCopyRequest: Identifiable {
    let id = UUID()
    let action: VirtualCopyAction
    let asset: AssetRecord
    let suggestedName: String
    let copy: LibraryVirtualCopy?
}

extension AppModel {
    func requestVirtualCopy(_ action: VirtualCopyAction, for asset: AssetRecord) {
        guard !isTriageScope, !isHistoryScope, editingAdmissions[asset.physicalAssetID] != nil else { return }
        let copy = libraryCopies.first { $0.id == asset.id }
        guard action == .create || copy != nil else { return }
        let names = Set(libraryCopies.filter { $0.sourceID == asset.physicalAssetID }.map(\.name))
        var ordinal = 1
        while names.contains("副本 \(ordinal)") { ordinal += 1 }
        virtualCopyRequest = .init(action: action, asset: asset, suggestedName: action == .create ? "副本 \(ordinal)" : copy?.name ?? "", copy: copy)
    }

    func commitVirtualCopy(_ request: VirtualCopyRequest, name: String) async throws {
        guard virtualCopyRequest?.id == request.id, let store else { throw EditingError.staleSource }
        let asset = request.asset
        if request.action == .create {
            try await editing?.awaitPendingRenditionWrites(for: asset.id)
            let copy = try await Task.detached(priority: .userInitiated) {
                let decoder = asset.availability == .available ? try DevelopmentRAWSourcePolicy.decoderForNewWork(at: asset.resolvedURL) : nil
                return try store.createVirtualCopy(of: asset, name: name, id: request.id.uuidString, rawDecoder: decoder)
            }.value
            finishVirtualCopyChange(copy, undoName: nil, undoRemoved: true, undoFocus: asset.id, focus: copy.id)
        } else {
            guard let prior = request.copy else { throw EditingError.missingWork }
            let removing = request.action == .remove
            let copy = try store.updateVirtualCopy(prior, name: removing ? nil : name, removed: removing ? true : nil)
            finishVirtualCopyChange(copy, undoName: removing ? nil : prior.name, undoRemoved: removing ? false : nil,
                                    undoFocus: copy.id, focus: removing ? copy.sourceID : copy.id)
        }
        if virtualCopyRequest?.id == request.id { virtualCopyRequest = nil }
    }
}
