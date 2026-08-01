import SwiftUI

struct AppRowView: View {
    let dashboard: AppDashboard
    let unreadCount: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: dynamicTypeSize.isAccessibilitySize ? 10 : 14) {
            AppIconView(
                asset: dashboard.app.iconAsset,
                appName: dashboard.app.name,
                size: dynamicTypeSize.isAccessibilitySize ? 44 : 48
            )
            content
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
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

                if !dashboard.availablePlatforms.isEmpty {
                    ForEach(dashboard.availablePlatforms, id: \.self) { platform in
                        PlatformSummaryRow(
                            platform: platform,
                            release: dashboard.currentRelease(in: platform),
                            build: dashboard.latestBuild(in: platform)
                        )
                    }
                    if dashboard.availablePlatforms.count == 1,
                       let submittedDate = dashboard.currentRelease?.submittedDate {
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
                            .fontWeight(.semibold).foregroundStyle(.tint)
                    }
    }
}

private struct PlatformSummaryRow: View {
    let platform: AppRelease.Platform
    let release: AppRelease?
    let build: BuildInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) { content }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 7) {
            PlatformLabel(platform: platform)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let release {
                Text(release.version).fontWeight(.medium)
            } else if let build {
                Text("Build \(build.buildNumber)").fontWeight(.medium)
            } else {
                Text("No release")
            }
        }
        if let release {
            HStack(spacing: 5) {
                Image(systemName: release.state.symbol).foregroundStyle(release.state.tint)
                Text(release.state.title).foregroundStyle(.primary)
            }
        } else if let build {
            HStack(spacing: 5) {
                Image(systemName: build.processingState.symbol)
                    .foregroundStyle(build.processingState.tint)
                Text(build.processingState.title).foregroundStyle(.primary)
            }
        }
    }
}
