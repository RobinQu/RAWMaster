import AppKit
import Combine
import SwiftUI

/// Local presentation intent. This never enters catalogue records or the operation log.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var preferredColorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
    func resolve(system: ResolvedAppearance) -> ResolvedAppearance {
        switch self { case .system: return system; case .light: return .light; case .dark: return .dark }
    }
}
enum ResolvedAppearance: String {
    case light, dark
    static func resolve(_ appearance: NSAppearance?) -> ResolvedAppearance {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
    var title: String { self == .dark ? "深色" : "浅色" }
}

@MainActor
final class AppearanceController: ObservableObject {
    static let preferenceKey = "appearance.preference"
    @Published private(set) var preference: AppearancePreference
    @Published private(set) var resolved: ResolvedAppearance
    private let defaults: UserDefaults
    private let systemAppearance: @MainActor () -> NSAppearance?
    private let applyAppearance: @MainActor (NSAppearance?) -> Void
    private let applyDockIcon: @MainActor (NSImage?) -> Void
    private let icon: @MainActor (ResolvedAppearance) -> NSImage?
    private var observation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard,
         systemAppearance: @escaping @MainActor () -> NSAppearance? = { NSApplication.shared.effectiveAppearance },
         applyAppearance: @escaping @MainActor (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 },
         applyDockIcon: @escaping @MainActor (NSImage?) -> Void = { NSApplication.shared.applicationIconImage = $0 },
         icon: @escaping @MainActor (ResolvedAppearance) -> NSImage? = { BrandArtwork.image(for: $0) },
         observeSystem: Bool = true) {
        self.defaults = defaults; self.systemAppearance = systemAppearance
        self.applyAppearance = applyAppearance; self.applyDockIcon = applyDockIcon; self.icon = icon
        let savedPreference = AppearancePreference(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "system") ?? .system
        preference = savedPreference
        resolved = savedPreference.resolve(system: ResolvedAppearance.resolve(systemAppearance()))
        applyIntent()
        if observeSystem {
            let application = NSApplication.shared
            observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSystemAppearance() }
            }
            notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: application, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshSystemAppearance() }
            })
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshSystemAppearance() }
            })
        }
    }
    func setPreference(_ newPreference: AppearancePreference) {
        guard newPreference != preference else { return }
        defaults.set(newPreference.rawValue, forKey: Self.preferenceKey)
        preference = newPreference
        applyIntent()
    }
    func refreshSystemAppearance() {
        let next = preference.resolve(system: ResolvedAppearance.resolve(systemAppearance()))
        if next != resolved { resolved = next }
    }
    private func applyIntent() {
        let appearance: NSAppearance?
        switch preference { case .system: appearance = nil; case .light: appearance = NSAppearance(named: .aqua); case .dark: appearance = NSAppearance(named: .darkAqua) }
        // Clear manual application appearance before resolving system; effectiveAppearance
        // would otherwise still describe the previous manual override.
        applyAppearance(appearance)
        refreshSystemAppearance()
        // nil restores native Dock icon policy, including the independent macOS icon style.
        applyDockIcon(preference == .system ? nil : icon(resolved))
    }
    deinit {
        for token in notifications { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

@MainActor
enum BrandArtwork {
    private static let light = load("DockIcon-Light")
    private static let dark = load("DockIcon-Dark")
    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    static func image(for appearance: ResolvedAppearance) -> NSImage? { appearance == .dark ? dark : light }
}
private struct ResolvedAppAppearanceKey: EnvironmentKey { static let defaultValue = ResolvedAppearance.light }
extension EnvironmentValues {
    var resolvedAppAppearance: ResolvedAppearance {
        get { self[ResolvedAppAppearanceKey.self] }
        set { self[ResolvedAppAppearanceKey.self] = newValue }
    }
}
struct BrandIconView: View {
    @Environment(\.resolvedAppAppearance) private var appearance
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let icon = BrandArtwork.image(for: appearance) { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "camera.aperture").foregroundStyle(AppPalette.accent) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Neutral dynamic surfaces and semantic state colors. Photo pixels are never themed.
enum AppPalette {
    static func isDark(_ appearance: NSAppearance) -> Bool { ResolvedAppearance.resolve(appearance) == .dark }
    private static func neutral(light: CGFloat, dark: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { NSColor(calibratedWhite: isDark($0) ? dark : light, alpha: alpha) }
    }
    private static func state(light: NSColor, dark: NSColor) -> Color { Color(nsColor: NSColor(name: nil) { isDark($0) ? dark : light }) }
    static let canvasNSColor = neutral(light: 0.94, dark: 0.075)
    static let panelNSColor = neutral(light: 0.98, dark: 0.105)
    static let canvas = Color(nsColor: canvasNSColor)
    static let panel = Color(nsColor: panelNSColor)
    static let thumbnailWell = Color(nsColor: neutral(light: 0.88, dark: 0.055))
    static let overlay = Color(nsColor: neutral(light: 0.98, dark: 0.12, alpha: 0.94))
    static let boundary = Color(nsColor: .separatorColor)
    static let accent = state(light: NSColor(calibratedRed: 0, green: 0.40, blue: 0.57, alpha: 1), dark: NSColor(calibratedRed: 0.26, green: 0.80, blue: 0.94, alpha: 1))
    static let keep = state(light: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.20, alpha: 1), dark: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.42, alpha: 1))
    static let warning = state(light: NSColor(calibratedRed: 0.60, green: 0.29, blue: 0.02, alpha: 1), dark: NSColor(calibratedRed: 0.98, green: 0.64, blue: 0.22, alpha: 1))
    static let rating = state(light: NSColor(calibratedRed: 0.55, green: 0.39, blue: 0, alpha: 1), dark: NSColor(calibratedRed: 0.98, green: 0.81, blue: 0.15, alpha: 1))
}

struct AppearanceSettingsView: View {
    @ObservedObject var appearance: AppearanceController
    var body: some View {
        Form {
            Section {
                Picker("界面外观", selection: Binding(get: { appearance.preference }, set: { appearance.setPreference($0) })) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.radioGroup)
                HStack(spacing: 12) {
                    BrandIconView(size: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前：\(appearance.preference.title) · \(appearance.resolved.title)")
                        Text("自动保存，切换立即生效。跟随系统使用 macOS 的外观与自动日夜切换。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            } header: { Text("外观") }
            Section {
                Text("手动选择时，运行中的 Dock 图标随界面变化。跟随系统时由 macOS 选择图标外观；Finder 等位置始终按系统设置显示。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped).padding(16).frame(width: 510, height: 325)
            .preferredColorScheme(appearance.preference.preferredColorScheme)
            .environment(\.resolvedAppAppearance, appearance.resolved)
    }
}
