import SwiftUI

struct AppOverviewView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @Binding var selectedTab: DashboardTab
    @State private var selectedPlatform: AppRelease.Platform?

    var body: some View {
        Group {
            if let dashboard {
                List {
                    OverviewAppHeader(dashboard: dashboard, selectedPlatform: $selectedPlatform)

                    if model.showingCachedData {
                        DataStatusBanner(lastUpdated: model.lastUpdated, issue: model.lastRefreshIssue)
                    }

                    CurrentReleaseOverviewSection(
                        dashboard: dashboard,
                        platform: selectedPlatform,
                        onRetry: refresh
                    )
                    LatestBuildOverviewSection(
                        dashboard: dashboard,
                        platform: selectedPlatform,
                        onRetry: refresh
                    )
                    LatestReviewOverviewSection(
                        review: dashboard.newestReview,
                        issue: dashboard.sectionIssues[.reviews],
                        isUnread: dashboard.newestReview.map { model.unreadReviewIDs.contains($0.id) } ?? false,
                        onOpen: { selectedTab = .reviews },
                        onRetry: refresh
                    )
                    AnalyticsOverviewSection(
                        state: model.analyticsState(for: dashboard.id),
                        onOpen: { selectedTab = .analytics }
                    )
                }
                .refreshable { await model.refresh() }
                .task(id: dashboard.id) {
                    restorePlatform(for: dashboard)
                    await model.prepareAnalytics(appID: dashboard.id)
                }
                .onChange(of: selectedPlatform) { _, value in
                    guard let value else { return }
                    UserDefaults.standard.set(value.rawValue, forKey: platformKey(for: dashboard.id))
                }
            } else {
                ChooseAppView()
            }
        }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { AppContextToolbar(dashboards: model.dashboards, selectedAppID: $selectedAppID) }
    }

    private func restorePlatform(for dashboard: AppDashboard) {
        let saved = UserDefaults.standard.string(forKey: platformKey(for: dashboard.id))
            .flatMap(AppRelease.Platform.init(rawValue:))
        selectedPlatform = saved.flatMap { dashboard.availablePlatforms.contains($0) ? $0 : nil }
            ?? dashboard.preferredPlatform
    }

    private func platformKey(for appID: String) -> String { "ReviewBar.platform.\(appID)" }

    private func refresh() {
        Task { await model.refresh() }
    }
}

private struct OverviewAppHeader: View {
    let dashboard: AppDashboard
    @Binding var selectedPlatform: AppRelease.Platform?

    var body: some View {
        Section {
            HStack(spacing: 14) {
                AppIconView(asset: dashboard.app.iconAsset, appName: dashboard.app.name, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dashboard.app.name)
                        .font(.title2.bold())
                    Text(dashboard.app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            PlatformPicker(platforms: dashboard.availablePlatforms, selection: $selectedPlatform)
        }
    }
}

private struct CurrentReleaseOverviewSection: View {
    let dashboard: AppDashboard
    let platform: AppRelease.Platform?
    let onRetry: () -> Void

    var body: some View {
        Section {
            if let issue = dashboard.sectionIssues[.releases] {
                SectionIssueView(issue: issue, retry: onRetry)
            }
            if let release = dashboard.currentRelease(in: platform) {
                NavigationLink(value: OverviewRoute.releaseHistory(platform)) {
                    OperationalStatusRow(
                        title: "Version \(release.version)",
                        status: release.state.title,
                        symbol: release.state.symbol,
                        tint: release.state.tint,
                        detail: release.submittedDate.map { "Submitted \(DisplayFormatters.relative($0))" },
                        secondaryDetail: release.reviewSubmissionState?.displayStatus
                    )
                }
                .accessibilityHint("Opens release history and lifecycle details")
            } else if dashboard.sectionIssues[.releases] == nil {
                Text("No App Store version is available for this platform.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Current Release")
        } footer: {
            Text("Release History contains version timelines, authoritative Apple timestamps, and locally observed transitions.")
        }
    }
}

private struct LatestBuildOverviewSection: View {
    let dashboard: AppDashboard
    let platform: AppRelease.Platform?
    let onRetry: () -> Void

    var body: some View {
        Section("Latest Build") {
            if let issue = dashboard.sectionIssues[.builds] {
                SectionIssueView(issue: issue, retry: onRetry)
            }
            if let build = dashboard.latestBuild(in: platform) {
                NavigationLink(value: OverviewRoute.builds(platform)) {
                    OperationalStatusRow(
                        title: build.version.map { "\($0) (\(build.buildNumber))" } ?? "Build \(build.buildNumber)",
                        status: build.expired ? "Expired" : build.processingState.title,
                        symbol: build.expired ? "clock.badge.xmark" : build.processingState == .processing ? "hourglass" : "checkmark.circle.fill",
                        tint: build.expired ? .secondary : build.processingState == .processing ? .orange : .green,
                        detail: build.uploadedDate.map { "Uploaded \(DisplayFormatters.relative($0))" },
                        secondaryDetail: build.expirationDate.map {
                            build.expired ? "Expired \(DisplayFormatters.relative($0))" : "Expires \(DisplayFormatters.relative($0))"
                        }
                    )
                }
                .accessibilityHint("Opens builds and TestFlight details")
            } else if dashboard.sectionIssues[.builds] == nil {
                Text("No builds are available for this platform.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LatestReviewOverviewSection: View {
    let review: CustomerReview?
    let issue: SectionIssue?
    let isUnread: Bool
    let onOpen: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Section("Latest Review") {
            if let issue {
                SectionIssueView(issue: issue, retry: onRetry)
            }
            if let review {
                Button(action: onOpen) {
                    ReviewSnapshot(review: review, isUnread: isUnread)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Reviews")
            } else if issue == nil {
                Text("No customer reviews yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AnalyticsOverviewSection: View {
    let state: AnalyticsLoadState
    let onOpen: () -> Void

    var body: some View {
        Section {
            AnalyticsOverviewSnapshot(state: state)
            Button("View Analytics", systemImage: "chart.xyaxis.line", action: onOpen)
        } header: {
            Text("Analytics Snapshot")
        } footer: {
            Text("Analytics uses cached Apple reports and never blocks this operational overview.")
        }
    }
}

private struct OperationalStatusRow: View {
    let title: String
    let status: String
    let symbol: String
    let tint: Color
    let detail: String?
    let secondaryDetail: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) { headline }
                } else {
                    HStack(alignment: .firstTextBaseline) { headline }
                }
            }
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            if let secondaryDetail {
                Text(secondaryDetail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var headline: some View {
        Text(title).font(.headline).foregroundStyle(.primary)
        Spacer(minLength: 6)
        Label(status, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
    }
}

private struct ReviewSnapshot: View {
    let review: CustomerReview
    let isUnread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                StarRatingView(rating: review.rating)
                if isUnread {
                    Label("New", systemImage: "circle.fill")
                        .font(.caption.bold())
                }
                Spacer()
                Text(DisplayFormatters.relative(review.createdDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(review.title).font(.headline).foregroundStyle(.primary)
            Text(review.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let territory = DisplayFormatters.territory(review.territory) {
                Text(territory).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct AnalyticsOverviewSnapshot: View {
    let state: AnalyticsLoadState

    var body: some View {
        if let dataset = state.cachedDataset {
            let summary = dataset.summary(range: .sevenDays)
            VStack(spacing: 8) {
                SnapshotValueRow(title: "Downloads", value: summary.totalDownloads)
                SnapshotValueRow(title: "Impressions", value: summary.values[.impressions] ?? .notAvailable)
                SnapshotValueRow(title: "Sessions", value: summary.values[.sessions] ?? .notAvailable)
                if let through = summary.coverageEnd {
                    Text("Last 7 days · data through \(through.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            switch state {
            case .notEnabled:
                Label("Analytics isn't enabled for this app.", systemImage: "chart.xyaxis.line")
                    .foregroundStyle(.secondary)
            case .generating:
                Label("Apple is preparing Analytics reports.", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .permissionRequired:
                Label("Analytics permission is required.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            default:
                Text("Open Analytics to load Apple report data.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SnapshotValueRow: View {
    let title: String
    let value: AnalyticsMetricValue

    var body: some View {
        LabeledContent(title) {
            Text(display).monospacedDigit()
        }
    }

    private var display: String {
        switch value {
        case .value(let number): number.formatted(.number.precision(.fractionLength(0)))
        case .noData: "No Data"
        case .notAvailable: "Not Available"
        case .insufficientData: "Insufficient"
        }
    }
}

extension String {
    var displayStatus: String {
        split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }
}
