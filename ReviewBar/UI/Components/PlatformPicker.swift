import SwiftUI

struct PlatformPicker: View {
    let platforms: [AppRelease.Platform]
    @Binding var selection: AppRelease.Platform?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if platforms.count > 1 {
            if dynamicTypeSize.isAccessibilitySize {
                LabeledContent("Platform") {
                    Picker("Platform", selection: $selection) {
                        platformOptions
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Platform")
                    .accessibilityValue(selection?.label ?? "Not selected")
                }
            } else {
                Picker("Platform", selection: $selection) {
                    platformOptions
                }
                .pickerStyle(.segmented)
                .accessibilityValue(selection?.label ?? "Not selected")
            }
        } else if let platform = platforms.first {
            Label(platform.label, systemImage: platform.symbol)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var platformOptions: some View {
        ForEach(platforms, id: \.self) { platform in
            Label(platform.label, systemImage: platform.symbol)
                .tag(Optional(platform))
        }
    }
}
