import Foundation

public enum CatalogImportDisposition: String, CaseIterable, Codable, Sendable {
    case admitted, sequenceOnly, excluded, failed

    public var title: String {
        switch self {
        case .admitted: "纳入项目"
        case .sequenceOnly: "仅序列纳入"
        case .excluded: "排除原件"
        case .failed: "保留失败记录"
        }
    }
}

public struct CatalogSealMember: Identifiable, Sendable {
    public var id: String { occurrenceID }
    public let occurrenceID: String
    public let assetID: String
    public let filename: String
    public let contentID: String?
    public let available: Bool
    public let requiredForSequence: Bool
    public let defaultDisposition: CatalogImportDisposition

    public init(occurrenceID: String, assetID: String, filename: String, contentID: String?,
                available: Bool, requiredForSequence: Bool, disposition: CatalogImportDisposition) {
        self.occurrenceID = occurrenceID
        self.assetID = assetID
        self.filename = filename
        self.contentID = contentID
        self.available = available
        self.requiredForSequence = requiredForSequence
        self.defaultDisposition = disposition
    }

    public var canAdmit: Bool { contentID != nil && available }
}

public struct CatalogSealItem: Codable, Sendable, Equatable {
    public let occurrenceID: String
    public let disposition: CatalogImportDisposition
    public let contentID: String?
}

public struct CatalogSealDraft: Sendable {
    public let members: [CatalogSealMember]
    public private(set) var decisions: [String: CatalogImportDisposition] = [:]
    public var confirmedFailures = false

    public init(members: [CatalogSealMember]) { self.members = members }

    public func decision(for member: CatalogSealMember) -> CatalogImportDisposition {
        decisions[member.id] ?? member.defaultDisposition
    }

    public mutating func decide(_ value: CatalogImportDisposition, for member: CatalogSealMember) {
        guard choices(for: member).contains(value) else { return }
        if value == member.defaultDisposition { decisions.removeValue(forKey: member.id) }
        else { decisions[member.id] = value }
    }

    public func choices(for member: CatalogSealMember) -> [CatalogImportDisposition] {
        if member.canAdmit { return [.admitted, .sequenceOnly, .excluded] }
        if member.contentID == nil { return [.failed] }
        return [.failed, .excluded]
    }

    public var needsFailureConfirmation: Bool {
        members.contains { decision(for: $0) == .failed }
    }

    public func items() throws -> [CatalogSealItem] {
        guard Set(members.map(\.id)).count == members.count else { throw LibraryEngineError("会话中的文件出现记录重复") }
        guard !needsFailureConfirmation || confirmedFailures else { throw LibraryEngineError("请确认本次保留失败记录") }
        return try members.map { member in
            let value = decision(for: member)
            guard choices(for: member).contains(value) else {
                throw LibraryEngineError("\(member.filename) 的可用性已变化，请核对该文件")
            }
            return CatalogSealItem(occurrenceID: member.occurrenceID, disposition: value, contentID: member.contentID)
        }.sorted { $0.occurrenceID < $1.occurrenceID }
    }
}

#if os(macOS)
import SwiftUI

public struct ImportSealReview: View {
    @Binding private var draft: CatalogSealDraft
    @State private var filter = ""

    public init(draft: Binding<CatalogSealDraft>) { _draft = draft }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("按文件名查找", text: $filter)
            List {
                ForEach(draft.members.filter { filter.isEmpty || $0.filename.localizedCaseInsensitiveContains(filter) }) { member in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(member.filename).lineLimit(1)
                            if member.requiredForSequence && draft.decision(for: member) == .excluded {
                                Text("序列将保留此帧的缺口").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("完成时的处置", selection: Binding(get: { draft.decision(for: member) },
                            set: { draft.decide($0, for: member) })) {
                            ForEach(draft.choices(for: member), id: \.self) { value in Text(value.title).tag(value) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }.frame(minHeight: 125)
            if draft.needsFailureConfirmation {
                Toggle("已核对失败项，本次只保存其历史记录", isOn: $draft.confirmedFailures)
            }
        }
    }
}
#endif
