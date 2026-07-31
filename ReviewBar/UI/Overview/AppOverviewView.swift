import SwiftUI

struct AppOverviewView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @Binding var selectedTab: DashboardTab

    var body: some View {
        Group {
            if let dashboard {
                List {
                    if let current = dashboard.currentRelease {
                        Section("Release Status") {
                            Button {
                                selectedTab = .releases
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Version \(current.version)")
                                            .font(.title2.bold())
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        ReleaseStatusLabel(state: current.state)
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
                        }
                    } else if let issue = dashboard.sectionIssues[.releases] {
                        Section("Release Status") {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                    } else {
                        Section("Release Status") {
                            Text("No App Store versions are available for this app.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let live = dashboard.liveRelease,
                       live.id != dashboard.currentRelease?.id {
                        Section("Live on the App Store") {
                            LabeledContent("Version", value: live.version)
                            ReleaseStatusLabel(state: live.state)
                        }
                    }

                    Section("Latest Upload") {
                        if let build = dashboard.latestBuild {
                            Button {
                                selectedTab = .builds
                            } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(build.version.map { "\($0) (\(build.buildNumber))" } ?? "Build \(build.buildNumber)")
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        BuildStatusLabel(build: build)
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
                        } else if let issue = dashboard.sectionIssues[.builds] {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        } else {
                            Text("No builds are available.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Newest Review") {
                        if let review = dashboard.newestReview {
                            NavigationLink(value: review) {
                                ReviewPreview(review: review, isUnread: model.unreadReviewIDs.contains(review.id))
                            }
                        } else if let issue = dashboard.sectionIssues[.reviews] {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        } else {
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
}

private struct ReviewPreview: View {
    let review: CustomerReview
    let isUnread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                StarRatingView(rating: review.rating)
                if isUnread {
                    Text("New")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                }
                Spacer()
                Text(DisplayFormatters.relative(review.createdDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(review.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(review.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(review.reviewerNickname)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension String {
    var displayStatus: String {
        split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }
}
