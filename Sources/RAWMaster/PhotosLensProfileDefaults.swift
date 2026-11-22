import Combine
import Foundation
import RAWMasterCore

struct DevelopmentLensProfileDefaultsV1: Codable, Equatable {
    var enabled: Bool
    var distortion: Double
    var vignetting: Double
    static let standard = Self(enabled: true, distortion: 1, vignetting: 1)
    func validate() throws {
        guard distortion.isFinite, vignetting.isFinite, (0...2).contains(distortion), (0...2).contains(vignetting) else {
            throw EditingError.invalidRecipe
        }
    }
}

/// Application preference store, deliberately outside the recipe and imaging engine.
final class DevelopmentLensProfileDefaultsStore: ObservableObject {
    static let storageKey = "photos.optics.lensProfileDefaults.v1"
    @Published private(set) var values: [String: DevelopmentLensProfileDefaultsV1]
    private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: DevelopmentLensProfileDefaultsV1].self, from: data),
           decoded.values.allSatisfy({ (try? $0.validate()) != nil }) {
            values = decoded
        } else { values = [:] }
    }
    func value(for profile: DevelopmentLensProfileV3) -> DevelopmentLensProfileDefaultsV1 {
        values[profile.id] ?? .standard
    }
    func save(_ value: DevelopmentLensProfileDefaultsV1, for profile: DevelopmentLensProfileV3) throws {
        try value.validate()
        values[profile.id] = value
        try persist()
    }
    func reset(for profile: DevelopmentLensProfileV3) throws {
        values.removeValue(forKey: profile.id)
        try persist()
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(values)
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum PhotosOpticsProfileSelection {
    static func applying(_ profile: DevelopmentLensProfileV3,
                         to current: DevelopmentOpticsV3,
                         defaults: DevelopmentLensProfileDefaultsStore) -> DevelopmentOpticsV3 {
        let value = defaults.value(for: profile)
        var next = current
        next.lensProfile = profile; next.lensProfileEnabled = value.enabled
        next.profileDistortionAmount = value.distortion; next.profileVignettingAmount = value.vignetting
        return next
    }
}
