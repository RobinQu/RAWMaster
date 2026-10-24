import Foundation
import RAWMasterCore

/// Discovery order is an implementation detail of the filesystem, not a shot order.
/// Keep import sessions together and use a stable natural path order within each one.
enum AssetBrowserOrder {
    static func sorted(_ assets: [AssetRecord], sessions: [ImportSession]) -> [AssetRecord] {
        let ranks = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
        let locale = Locale(identifier: "en_US_POSIX")
        return assets.sorted { left, right in
            let leftRank = ranks[left.sessionID] ?? Int.max
            let rightRank = ranks[right.sessionID] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
            let order = left.relativePath.compare(right.relativePath, options: [.numeric, .caseInsensitive], locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
            return left.id < right.id
        }
    }
}
