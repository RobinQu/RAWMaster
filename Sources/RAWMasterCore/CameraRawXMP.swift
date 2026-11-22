import Foundation

/// A bounded reader for the Camera Raw vocabulary inside an RDF description. Unconsumed
/// attributes and subtrees remain in the original bytes in the content store.
struct CameraRawDescription {
  var fields: Set<String> = []
  var scalars: [String: String] = [:]
  var localized: [String: [String: String]] = [:]
  var sequences: [String: [String]] = [:]
  var look: [String: String] = [:]
  var isoCount = 0
  var corrections: [CameraRawCorrection] = []
  var lensBlur: [String: String] = [:]
  var sourceFields: [PresetSourceField] = []
  var omittedSourceFieldCount = 0

  func name(_ field: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
    let names = localized[field] ?? [:]
    var keys: [String] = []
    for preference in preferredLanguages {
      var parts = preference.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")
      while !parts.isEmpty {
        keys.append(parts.joined(separator: "-"))
        parts.removeLast()
      }
      if let language = keys.last { keys += names.keys.sorted().filter { $0.hasPrefix(language + "-") } }
    }
    keys += ["x-default", ""] + names.keys.sorted()
    return (keys.compactMap { names[$0] } + [scalars[field]].compactMap { $0 })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
  }
}

private final class CameraRawRDFReader: NSObject, XMLParserDelegate {
  let collectFields: Bool
  init(collectFields: Bool) { self.collectFields = collectFields }
  private let camera = "http://ns.adobe.com/camera-raw-settings/1.0/"
  private let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  private struct Frame {
    let name: String
    let namespaces: [String: String]
    let language: String
    var text = ""
  }
  private var stack: [Frame] = []
  private var descriptionIndex: Int?
  private var subject: String?
  private var nodes = 0
  private var failed = false
  private(set) var result = CameraRawDescription()

  func read(_ data: Data) throws -> CameraRawDescription {
    guard data.count <= PresetExchangeLimits.xmpBytes,
          let xml = String(data: data, encoding: .utf8), !xml.utf8.contains(0),
          xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
          xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
      throw PresetExchangeError.invalid("XMP 超限、编码不受支持或含外部声明")
    }
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), !failed, !result.fields.isEmpty else {
      throw PresetExchangeError.invalid("未能读取 Camera Raw RDF 描述")
    }
    return result
  }

  private func normalize(_ name: String, namespaces: [String: String], attribute: Bool = false) -> String {
    let parts = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard let local = parts.last else { return name }
    let prefix = parts.count == 2 ? String(parts[0]) : ""
    let uri = attribute && prefix.isEmpty ? nil : namespaces[prefix]
    if uri == camera { return "crs:" + local }
    if uri == rdf { return "rdf:" + local }
    return "other:" + local
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
              qualifiedName qName: String?, attributes: [String: String]) {
    nodes += 1
    guard !Task.isCancelled, nodes <= 80_000, stack.count < 64, attributes.count <= 2048 else {
      failed = true; parser.abortParsing(); return
    }
    var ns = stack.last?.namespaces ?? [:]
    for (key, value) in attributes {
      if key == "xmlns" { ns[""] = value }
      else if key.hasPrefix("xmlns:") { ns[String(key.dropFirst(6))] = value }
    }
    let name = normalize(elementName, namespaces: ns)
    let index = stack.count
    let parent = stack.last?.name
    let language = attributes["xml:lang"]?.lowercased() ?? stack.last?.language ?? ""
    stack.append(Frame(name: name, namespaces: ns, language: language))
    if name == "rdf:Description", parent == "rdf:RDF", index <= 2 {
      let about = attributes.first { normalize($0.key, namespaces: ns, attribute: true) == "rdf:about" }?.value ?? ""
      if let subject, subject != about { failed = true; parser.abortParsing(); return }
      subject = about
      descriptionIndex = index
      for (key, value) in attributes {
        let field = normalize(key, namespaces: ns, attribute: true)
        guard field.hasPrefix("crs:") else { continue }
        assign(String(field.dropFirst(4)), value, parser: parser)
        if collectFields { remember("rdf:Description/@" + field, value: value) }
      }
      return
    }
    guard let root = descriptionIndex, index > root else { return }
    let property = stack[root + 1].name
    guard property.hasPrefix("crs:") else { return }
    let key = String(property.dropFirst(4))
    if collectFields {
      let path = stack[(root + 1)...].map(\.name).joined(separator: "/")
      for (rawKey, value) in attributes {
        let field = normalize(rawKey, namespaces: ns, attribute: true)
        if field.hasPrefix("crs:") { remember(path + "/@" + field, value: value) }
      }
    }
    if key == "MaskGroupBasedCorrections" || key == "LensBlur" {
      let path = Array(stack[(root + 1)...].map(\.name))
      let attrs = attributes.compactMap { attr -> (String, String)? in
        let qualified = normalize(attr.key, namespaces: ns, attribute: true)
        guard qualified.hasPrefix("crs:"), attr.value.utf8.count <= 4096 else { return nil }
        return (String(qualified.dropFirst(4)), attr.value)
      }
      let props = Dictionary(attrs, uniquingKeysWith: { first, _ in first })
      guard props.count == attrs.count else { failed = true; parser.abortParsing(); return }
      if key == "LensBlur", index == root + 1 { result.lensBlur = props }
      if key == "MaskGroupBasedCorrections" {
        let correction = ["crs:MaskGroupBasedCorrections", "rdf:Seq", "rdf:li", "rdf:Description"]
        if path == correction {
          guard result.corrections.count < 512 else { failed = true; parser.abortParsing(); return }
          result.corrections.append(CameraRawCorrection(attributes: props))
        } else if path.starts(with: correction), let last = result.corrections.indices.last {
          if path == correction + ["crs:CorrectionMasks", "rdf:Seq", "rdf:li"] {
            result.corrections[last].masks.append(props)
          } else if name.hasPrefix("crs:"), name != "crs:CorrectionMasks" {
            result.corrections[last].nestedFields.insert(String(name.dropFirst(4)))
          }
        }
      }
    }
    if index == root + 1 {
      if result.fields.contains(key) { failed = true; parser.abortParsing(); return }
      result.fields.insert(key)
    }
    if key == "Look", (index == root + 1 || (index == root + 2 && name == "rdf:Description")) {
      for (fieldName, value) in attributes {
        let field = normalize(fieldName, namespaces: ns, attribute: true)
        if ["crs:UUID", "crs:Name", "crs:Amount"].contains(field) {
          result.look[String(field.dropFirst(4))] = String(value.prefix(512))
        }
      }
    }
    if key == "ISODependent", name == "rdf:li", index == root + 3 { result.isoCount += 1 }
  }

  private func assign(_ key: String, _ value: String, parser: XMLParser) {
    if result.fields.contains(key) { failed = true; parser.abortParsing(); return }
    result.fields.insert(key)
    // The original content store retains embedded Look tables of any permitted XMP size.
    if value.utf8.count <= 4096 { result.scalars[key] = value }
  }

  private func remember(_ path: String, value: String) {
    guard result.sourceFields.count < 2048 else { result.omittedSourceFieldCount += 1; return }
    let compact = value.utf8.count <= 512 ? value : "原文值共 \(value.utf8.count) 字节"
    result.sourceFields.append(.init(path: path, value: compact))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard descriptionIndex != nil, let last = stack.indices.last,
          !stack[last].name.hasPrefix("other:"), stack[last].text.utf8.count <= 4096 else { return }
    stack[last].text.append(contentsOf: string.prefix(4097))
  }

  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    if let string = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    guard let frame = stack.popLast(), let root = descriptionIndex else { return }
    let index = stack.count
    if index == root { descriptionIndex = nil; return }
    let value = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 4096 else { return }
    if collectFields, index >= root + 1 {
      let path = (stack.dropFirst(root + 1).map(\.name) + [frame.name]).joined(separator: "/")
      remember(path, value: value)
    }
    if index == root + 1, frame.name.hasPrefix("crs:") {
      result.scalars[String(frame.name.dropFirst(4))] = value
    } else if index > root + 1, stack[root + 1].name.hasPrefix("crs:") {
      let key = String(stack[root + 1].name.dropFirst(4))
      if index == root + 3, frame.name == "rdf:li" {
        if stack.last?.name == "rdf:Alt" { result.localized[key, default: [:]][frame.language] = value }
        else if stack.last?.name == "rdf:Seq", key.hasPrefix("ToneCurvePV2012") {
          result.sequences[key, default: []].append(value)
        }
      } else if key == "Look", index == root + 3, ["crs:UUID", "crs:Name", "crs:Amount"].contains(frame.name) {
        result.look[String(frame.name.dropFirst(4))] = value
      }
    }
  }
}

enum CameraRawXMP {
  static func read(_ data: Data, collectFields: Bool = false) throws -> CameraRawDescription {
    try CameraRawRDFReader(collectFields: collectFields).read(data)
  }
}

public struct PresetSourceField: Equatable, Sendable {
  public let path: String
  public let value: String
}
