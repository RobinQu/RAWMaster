import Foundation

/// Personal-trial automatic grouping: one successful, undoable pass per completed import.
/// The file lease survives awaits; no database transaction or connection lock does.
public final class AutomaticGroupingService: @unchecked Sendable {
  private let store: LibraryStore
  private let analyzer: AutomaticGroupingAnalyzer
  public init(store: LibraryStore, analyzer: @escaping AutomaticGroupingAnalyzer) {
    self.store = store; self.analyzer = analyzer
  }
  public func run(sessionID: String, checkCancellation: @escaping @Sendable () throws -> Void,
                  progress: @escaping @Sendable (TaskProgress) -> Void) async {
    var claimed: AutomaticGroupingInput?
    do {
      let lease = try store.acquireAutomaticGroupingLease(sessionID)
      defer { withExtendedLifetime(lease) {} }
      try checkCancellation()
      guard let input = try store.claimAutomaticGrouping(sessionID: sessionID) else {
        progress(TaskProgress(title: "自动分组", message: "本次导入已完成自动分组；人工修改和撤销会保留", isRunning: false))
        return
      }
      claimed = input
      progress(TaskProgress(title: "自动分组", total: input.assets.count, message: "分析连拍与间隔拍摄；所有照片保留"))
      let analysis = try await analyzer(input, checkCancellation, progress)
      try checkCancellation()
      if let batch = try store.prepareAutomaticGrouping(analysis, input: input, checkCancellation: checkCancellation) {
        try store.commitAutomaticGroupingBatch(batch, checkCancellation: checkCancellation)
      }
      let run = try store.automaticGroupingRun(sessionID: sessionID)
      progress(TaskProgress(title: "自动分组", completed: input.assets.count, total: input.assets.count,
        message: run?.message ?? "分析已完成，拍摄组待复核", isRunning: false))
    } catch {
      if let claimed { try? store.failAutomaticGrouping(claimed, error: error) }
      progress(TaskProgress(title: "自动分组未完成", message: "素材已导入并保留：" + error.localizedDescription, isRunning: false))
    }
  }
}
