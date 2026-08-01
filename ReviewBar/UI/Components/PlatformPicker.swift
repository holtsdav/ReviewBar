import SwiftUI

struct PlatformPicker: View {
    let platforms: [AppRelease.Platform]
    @Binding var selection: AppRelease.Platform?

    var body: some View {
        if platforms.count > 1 {
            Picker("Platform", selection: $selection) {
                ForEach(platforms, id: \.self) { platform in
                    Label(platform.label, systemImage: platform.symbol)
                        .tag(Optional(platform))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("App platform")
        } else if let platform = platforms.first {
            Label(platform.label, systemImage: platform.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
