import Foundation

enum SessionTaskKind: Equatable { case intake, grouping, quality, pairing }
struct SessionTaskState: Equatable {
    let id: UUID
    var kind: SessionTaskKind
    var sessionID: String?
    var isCancelling: Bool
    init(kind: SessionTaskKind, sessionID: String?, isCancelling: Bool = false, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.sessionID = sessionID; self.isCancelling = isCancelling
    }
}
struct SessionBatchCounts: Equatable {
    let fileCount, readyCount, failedCount, pendingCount, passedCount, excludedCount, reviewCount, groupCount: Int
    init(fileCount: Int = 0, readyCount: Int = 0, failedCount: Int = 0, pendingCount: Int = 0,
         passedCount: Int = 0, excludedCount: Int = 0, reviewCount: Int = 0, groupCount: Int = 0) {
        self.fileCount=fileCount; self.readyCount=readyCount; self.failedCount=failedCount
        self.pendingCount=pendingCount; self.passedCount=passedCount; self.excludedCount=excludedCount
        self.reviewCount=reviewCount; self.groupCount=groupCount
    }
}
