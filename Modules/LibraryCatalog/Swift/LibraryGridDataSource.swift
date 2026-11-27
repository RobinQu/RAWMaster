#if canImport(Combine)
import Combine
import Foundation

/// One serial reader prevents obsolete keystrokes from starting simultaneous index builds.
private actor LibraryPageReader {
    let database: URL
    let index: URL

    init(database: URL, index: URL) {
        self.database = database
        self.index = index
    }

    func read<Q: Encodable & Sendable, A: Decodable & Sendable>(
        _ query: CatalogGridRequest<Q>, as: A.Type
    ) throws -> CatalogGridPage<A> {
        try Task.checkCancellation()
        return try LibraryEngine.shared().request("page", at: database, index: index, payload: query,
                                                  as: CatalogGridPage<A>.self)
    }

    func isCurrent(_ selection: CatalogFrozenSelection) throws -> Bool {
        try LibraryEngine.shared().request("resolveSelection", at: database, payload: selection, as: CatalogJSON.self) != .null
    }
}

@MainActor
public final class LibraryGridDataSource<Asset: Decodable & Sendable, Query: Encodable & Sendable>: ObservableObject {
    @Published public private(set) var cards: [CatalogCard<Asset>] = []
    @Published public private(set) var totalFiles = 0
    @Published public private(set) var totalCaptures = 0
    @Published public private(set) var total = 0
    @Published public private(set) var facets: CatalogJSON?
    @Published public private(set) var errorDescription: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var displayedRevision: UInt64 = 0
    public private(set) var firstPageStartedAt: UInt64 = 0
    public private(set) var libraryID: String?
    public private(set) var watermark: Int64?
    public private(set) var generation: CatalogJSON?

    private let reader: LibraryPageReader
    private var request: CatalogGridRequest<Query>?
    private var nextCursor: CatalogJSON?
    public private(set) var epoch: UInt64 = 0
    private var task: Task<Void, Never>?

    public init(database: URL) {
        let cache = database.deletingLastPathComponent().appendingPathComponent("." + database.lastPathComponent + ".search.sqlite")
        reader = LibraryPageReader(database: database, index: cache)
    }

    public func replace(with query: CatalogGridRequest<Query>, startedAt: UInt64? = nil) {
        start(query, startedAt: startedAt)
    }

    public func refresh() {
        guard let request else { return }
        start(request)
    }

    public func cancel() {
        epoch &+= 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    private func start(_ query: CatalogGridRequest<Query>, startedAt: UInt64? = nil) {
        cancel()
        var first = query
        first.cursor = nil
        first.includeOrderedIDs = false
        request = first
        // Never display cards from a previous scope while eligibility is being refreshed.
        cards = []
        totalFiles = 0
        totalCaptures = 0
        total = 0
        facets = nil
        nextCursor = nil
        generation = nil
        watermark = nil
        errorDescription = nil
        let now = DispatchTime.now().uptimeNanoseconds
        firstPageStartedAt = min(startedAt ?? now, now)
        submit(first, appending: false)
        displayedRevision &+= 1
    }

    public func loadMore() {
        guard !isLoading, let nextCursor, var query = request else { return }
        query.cursor = nextCursor
        submit(query, appending: true)
    }

    private func submit(_ query: CatalogGridRequest<Query>, appending: Bool) {
        let expected = epoch
        isLoading = true
        task = Task { [weak self, reader] in
            do {
                let page = try await reader.read(query, as: Asset.self)
                guard let self, epoch == expected, !Task.isCancelled else { return }
                if page.status == "staleCursor" {
                    if appending { refresh() } else { fail("查询修订已过期，请刷新。") }
                    return
                }
                apply(page, appending: appending)
            } catch {
                guard let self, epoch == expected, !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func apply(_ page: CatalogGridPage<Asset>, appending: Bool) {
        guard page.status == "ok", let items = page.items, let files = page.totalFiles,
              let captures = page.totalCaptures, let count = page.total else {
            fail("资料库返回了不完整的分页结果。")
            return
        }
        cards = appending ? cards + items : items
        totalFiles = files
        totalCaptures = captures
        total = count
        facets = page.facets
        libraryID = page.libraryID
        watermark = page.watermark
        generation = page.generation
        nextCursor = page.nextCursor
        isLoading = false
        errorDescription = nil
        displayedRevision &+= 1
    }

    private func fail(_ message: String) {
        isLoading = false
        errorDescription = message
        facets = nil
        nextCursor = nil
        generation = nil
        watermark = nil
        cards = []
        totalFiles = 0
        totalCaptures = 0
        total = 0
        displayedRevision &+= 1
    }

    /// Attach the presented revision to the actual file IDs a user selected on loaded pages.
    public func visibleSelection(_ ids: [String]) throws -> CatalogFrozenSelection {
        guard let libraryID, let watermark, let request,
              Set(ids).isSubset(of: Set(cards.flatMap(\.matchedAssetIDs))) else {
            throw LibraryEngineError("当前结果已变化，请重新选择照片")
        }
        return CatalogFrozenSelection(libraryID: libraryID, watermark: watermark, projectID: request.projectID, assetIDs: ids)
    }

    /// Freeze all matching file IDs at the version actually presented before an all-results action.
    public func matchingIDs() async throws -> [String] {
        try await frozenSelection().assetIDs
    }

    public func readSelectionPage() async throws -> (page: CatalogGridPage<Asset>, selection: CatalogFrozenSelection) {
        guard var query = request, let libraryID, watermark != nil else {
            throw LibraryEngineError("请等待资料库完成查询")
        }
        let expected = epoch
        query.cursor = nil
        query.includeOrderedIDs = true
        let page = try await reader.read(query, as: Asset.self)
        guard expected == epoch, !Task.isCancelled else { throw CancellationError() }
        guard page.libraryID == libraryID, page.status == "ok", page.items != nil, page.total != nil,
              page.totalFiles != nil, page.totalCaptures != nil, let ids = page.orderedAssetIDs else {
            throw LibraryEngineError("无法核对当前资料库选区，请重新打开项目。")
        }
        return (page, CatalogFrozenSelection(libraryID: libraryID, watermark: page.watermark, projectID: query.projectID, assetIDs: ids))
    }

    public func displaySelectionPage(_ page: CatalogGridPage<Asset>) {
        cancel()
        apply(page, appending: false)
    }

    public func frozenSelection() async throws -> CatalogFrozenSelection {
        let displayed = try visibleSelection([])
        let expected = epoch, displayedGeneration = generation
        let (page, selection) = try await readSelectionPage()
        guard page.generation == displayedGeneration else { throw CatalogSelectionError.changed }
        if selection.watermark != displayed.watermark {
            guard try await reader.isCurrent(displayed) else { throw CatalogSelectionError.changed }
        }
        guard expected == epoch, !Task.isCancelled else { throw CancellationError() }
        return selection
    }
}
#endif
