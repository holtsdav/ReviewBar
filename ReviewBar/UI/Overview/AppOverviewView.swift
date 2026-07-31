import SwiftUI

struct AppOverviewView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @Binding var selectedTab: DashboardTab
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let dashboard {
                List {
                    SelectedAppHeader(name: dashboard.app.name)
                    if model.showingCachedData {
                        DataStatusBanner(lastUpdated: model.lastUpdated, issue: model.lastRefreshIssue)
                    }

                    Section("Release Status") {
                        if let issue = dashboard.sectionIssues[.releases] {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                        if let current = dashboard.currentRelease {
                            Button {
                                selectedTab = .releases
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    if dynamicTypeSize.isAccessibilitySize {
                                        VStack(alignment: .leading, spacing: 6) {
                                            releaseTitle(current)
                                            ReleaseStatusLabel(state: current.state)
                                        }
                                    } else {
                                        HStack(alignment: .firstTextBaseline) {
                                            releaseTitle(current)
                                            Spacer()
                                            ReleaseStatusLabel(state: current.state)
                                        }
                                    }
                                    if let submitted = current.submittedDate {
                                        LabeledContent("Submitted") {
                                            Text(DisplayFormatters.relative(submitted))
                                        }
                                    }
                                    if let submissionState = current.reviewSubmissionState {
                                        LabeledContent("Review submission") {
                                            Text(submissionState.displayStatus)
                                        }
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens releases")
                        } else if dashboard.sectionIssues[.releases] == nil {
                            Text("No App Store versions are available for this app.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let ready = dashboard.distributionReadyRelease,
                       ready.id != dashboard.currentRelease?.id {
                        Section("Ready for Distribution") {
                            LabeledContent("Version", value: ready.version)
                            ReleaseStatusLabel(state: ready.state)
                            Text("Availability can still depend on territory settings and active agreements.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Latest Upload") {
                        if let issue = dashboard.sectionIssues[.builds] {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                        if let build = dashboard.latestBuild {
                            Button {
                                selectedTab = .builds
                            } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    if dynamicTypeSize.isAccessibilitySize {
                                        VStack(alignment: .leading, spacing: 6) {
                                            buildTitle(build)
                                            BuildStatusLabel(build: build)
                                        }
                                    } else {
                                        HStack(alignment: .firstTextBaseline) {
                                            buildTitle(build)
                                            Spacer()
                                            BuildStatusLabel(build: build)
                                        }
                                    }
                                    if let uploaded = build.uploadedDate {
                                        Text("Uploaded \(DisplayFormatters.relative(uploaded))")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let expiration = build.expirationDate, !build.expired {
                                        Text("Expires \(DisplayFormatters.relative(expiration)) · \(DisplayFormatters.dateTime(expiration))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens builds")
                        } else if dashboard.sectionIssues[.builds] == nil {
                            Text("No builds are available.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Newest Review") {
                        if let issue = dashboard.sectionIssues[.reviews] {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                        if let review = dashboard.newestReview {
                            NavigationLink(value: review) {
                                ReviewPreview(review: review, isUnread: model.unreadReviewIDs.contains(review.id))
                            }
                        } else if dashboard.sectionIssues[.reviews] == nil {
                            Text("No customer reviews yet.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .refreshable { await model.refresh() }
                .navigationDestination(for: CustomerReview.self) { review in
                    ReviewDetailView(model: model, review: review)
                }
            } else {
                ChooseAppView()
            }
        }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppContextToolbar(dashboards: model.dashboards, selectedAppID: $selectedAppID)
        }
    }

    private func releaseTitle(_ release: AppRelease) -> some View {
        Text("Version \(release.version)")
            .font(.title2.bold())
            .foregroundStyle(.primary)
    }

    private func buildTitle(_ build: BuildInfo) -> some View {
        Text(build.version.map { "\($0) (\(build.buildNumber))" } ?? "Build \(build.buildNumber)")
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

private struct ReviewPreview: View {
    let review: CustomerReview
    let isUnread: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) { reviewMetadata }
            } else {
                HStack { reviewMetadata }
            }
            Text(review.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(review.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 3)
            Text(review.reviewerNickname)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var reviewMetadata: some View {
                StarRatingView(rating: review.rating)
                if isUnread {
                    Label("New", systemImage: "circle.fill")
                        .font(.caption.bold()).foregroundStyle(.primary)
                }
                Spacer()
                Text(DisplayFormatters.relative(review.createdDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
    }
}

extension String {
    var displayStatus: String {
        split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }
}
