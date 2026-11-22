import RAWMasterCore
import SwiftUI

struct PhotosSuperResolutionControl: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    @State private var errorText: String?

    var body: some View {
        VStack(alignment:.leading, spacing:5) {
            Toggle("超分辨率 2×", isOn:.init(get:{session.parameters.superResolution != nil},set:{enabled in
                do {
                    try session.apply(.setSuperResolution(enabled ? .photoUpconv7 : nil), event:.init(context:context,
                        control:.init(group:nil,name:"超分辨率 2×"),
                        nativeInput:.capture(control:"detail.superResolution",phase:"discrete",nativeEvent:true)))
                    errorText = nil
                } catch { errorText = error.localizedDescription }
            }))
            .accessibilityIdentifier("photos.detail.superResolution")
            if session.parameters.superResolution != nil {
                Text("将裁剪后照片的宽与高各放大 2 倍。").font(.caption).foregroundStyle(.secondary)
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(AppPalette.warning) }
        }
    }
}
