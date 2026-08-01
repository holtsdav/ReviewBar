import SwiftUI

struct ReleaseStatusLabel: View {
    let state: ReleaseState

    var body: some View {
        Label {
            Text(state.title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: state.symbol).foregroundStyle(state.tint)
        }
            .font(.subheadline.weight(.semibold))
            .accessibilityElement(children: .combine)
    }
}

struct BuildStatusLabel: View {
    let build: BuildInfo

    var body: some View {
        Group {
            if build.expired {
                Label {
                    Text("Expired").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.secondary)
                }
            } else if build.processingState == .processing {
                Label {
                    Text("Processing").foregroundStyle(.primary)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if build.processingState == .valid {
                Label {
                    Text("Ready").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else if build.processingState == .failed || build.processingState == .invalid {
                Label {
                    Text(build.processingState.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            } else {
                Label {
                    Text(build.processingState.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityElement(children: .combine)
    }
}

extension BuildInfo.ProcessingState {
    var symbol: String {
        switch self {
        case .processing: "hourglass"
        case .valid: "checkmark.circle.fill"
        case .failed, .invalid: "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .processing: .orange
        case .valid: .green
        case .failed, .invalid: .red
        default: .secondary
        }
    }
}
