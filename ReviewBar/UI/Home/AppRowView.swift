import SwiftUI

struct AppRowView: View {
    let dashboard: AppDashboard
    let unreadCount: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                content
            } else {
                HStack(alignment: .top, spacing: 14) {
                    AppGlyph(name: dashboard.app.name)
                    content
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
                Text(dashboard.app.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let release = dashboard.currentRelease {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(release.version).fontWeight(.medium)
                                ReleaseStatusLabel(state: release.state)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(release.version).fontWeight(.medium)
                                Text("·")
                                ReleaseStatusLabel(state: release.state)
                            }
                        }
                    }
                    .font(.subheadline)
                    if let submittedDate = release.submittedDate {
                        Text("Submitted \(DisplayFormatters.relative(submittedDate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No App Store releases")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 3) { activityDetails }
                    } else {
                        HStack(spacing: 8) { activityDetails }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private var activityDetails: some View {
                    if let build = dashboard.latestBuild {
                        Text("Build \(build.buildNumber) · \(build.expired ? "Expired" : build.processingState.title)")
                    }
                    if unreadCount > 0 {
                        Label("\(unreadCount) new \(unreadCount == 1 ? "review" : "reviews")", systemImage: "circle.fill")
                            .fontWeight(.semibold).foregroundStyle(.primary)
                    }
    }
}

private struct AppGlyph: View {
    let name: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.tint.opacity(0.13))
            Text(String(name.prefix(1)).uppercased())
                .font(.title2.bold())
                .foregroundStyle(.tint)
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}
