import SwiftUI

struct ReleaseStatusLabel: View {
    let state: ReleaseState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(state.tint)
            .accessibilityElement(children: .combine)
    }
}

struct BuildStatusLabel: View {
    let build: BuildInfo

    var body: some View {
        Group {
            if build.expired {
                Label("Expired", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else if build.processingState == .processing {
                Label {
                    Text("Processing")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .foregroundStyle(.blue)
            } else if build.processingState == .valid {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if build.processingState == .failed || build.processingState == .invalid {
                Label(build.processingState.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Label(build.processingState.title, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityElement(children: .combine)
    }
}

