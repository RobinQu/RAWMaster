import AppKit
import Foundation
import RAWMasterLibrary
import SwiftUI

/// Exercises the actual app's work card, editor sheet, slider and save action inside a private window.
@main @MainActor struct WorkEditUIProbe {
  static func element(_ window: NSWindow, matching predicate: (NSObject) -> Bool) -> NSObject? {
    var items: [NSObject] = [window]
    var seen = Set<ObjectIdentifier>()
    while let x = items.popLast() {
      guard seen.insert(ObjectIdentifier(x)).inserted else { continue }
      if predicate(x) { return x }
      items.append(contentsOf: attr(x, "accessibilityChildren") as? [NSObject] ?? [])
    }
    return nil
  }
  static func attr(_ node: NSObject, _ name: String) -> Any? {
    let sel = NSSelectorFromString(name)
    guard node.responds(to: sel) else { return nil }
    return node.perform(sel)?.takeUnretainedValue()
  }
  static func activate(_ node: NSObject, _ action: String) throws {
    let selector = NSSelectorFromString(action)
    guard node.responds(to: selector) else { throw ProbeError("Missing control action " + action) }
    _ = node.perform(selector)
  }
  static func until<T>(_ why: String, _ f: () -> T?) async throws -> T {
    let deadline = ContinuousClock.now + .seconds(18)
    while ContinuousClock.now < deadline {
      if let v = f() { return v }
      try await Task.sleep(for: .milliseconds(40))
    }
    throw ProbeError(why)
  }
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  static func run() async throws {
    let a = CommandLine.arguments
    let db = URL(fileURLWithPath: a[1])
    let master = a[2]
    let output = URL(fileURLWithPath: a[3])
    let writer = try ProbeWriter(db)
    let actions = CatalogActions(database: db) { try writer.transaction("command", $0) }
    let id = "ui-" + UUID().uuidString
    _ = try await actions.perform(
      "org.saveWork",
      [
        "workID": .string(id), "masterWorkID": .string(master),
        "kind": .string("virtual"), "name": .string("Presentation validation"),
      ])
    let previous = try await CatalogLocalEditing.open(id, actions: actions)
    let masterBefore = try await CatalogLocalEditing.open(master, actions: actions)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
    var didSave = false
    let host = NSHostingView(
      rootView: CatalogWorkMediaView(workID: id, actions: actions, didEdit: { didSave = true }))
    let window = NSWindow(
      contentRect: NSRect(x: -4000, y: -4000, width: 850, height: 540),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = true
    window.ignoresMouseEvents = true
    window.alphaValue = 0
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.orderBack(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    let open = try await until("Work card has no editor action") {
      element(window) { attr($0, "accessibilityIdentifier") as? String == "work.localEdit.open" }
    }
    try activate(open, "accessibilityPerformPress")
    let sheet = try await until("Editor sheet did not open for selected work") {
      window.attachedSheet
    }
    sheet.alphaValue = 0
    let slider = try await until("No native exposure slider") {
      element(sheet) { item in
        (attr(item, "accessibilityLabel") as? String) == "曝光"
          && item.responds(to: NSSelectorFromString("accessibilityPerformIncrement"))
      }
    }
    try activate(slider, "accessibilityPerformIncrement")
    let save = try await until("Save control stayed disabled") {
      element(sheet) { item in
        guard attr(item, "accessibilityIdentifier") as? String == "work.localEdit.save" else {
          return false
        }
        if let control = item as? NSControl { return control.isEnabled }
        if item.responds(to: NSSelectorFromString("isAccessibilityEnabled")) {
          return (item.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue == true
        }
        return true
      }
    }
    try activate(save, "accessibilityPerformPress")
    _ = try await until("App did not publish the work edit") { didSave ? true : nil }
    let saved = try await CatalogLocalEditing.open(id, actions: actions)
    let still = try await CatalogLocalEditing.open(master, actions: actions)
    guard saved.hasLocalVersion, saved.versionID != previous.versionID,
      saved.recipe.exposureEV != previous.recipe.exposureEV,
      still.versionID == masterBefore.versionID, still.recipe == masterBefore.recipe
    else { throw ProbeError("UI saved the wrong work or exposure") }
    let report: [String: Any] = [
      "workCardPressed": true, "editorSheetOpened": true, "exposureSliderAdjusted": true,
      "saveButtonPersistedVersion": true, "masterUnchanged": true,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: output, options: .withoutOverwriting)
  }
}
