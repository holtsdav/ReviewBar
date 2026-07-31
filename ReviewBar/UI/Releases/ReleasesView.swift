import SwiftUI

struct ReleasesView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @State private var observations: [ReleaseObservation] = []
    @State private var statistics = ReleaseStatistics(
        averageWaiting: nil,
        averageInReview: nil,
        fastestApproval: nil,
        longestApproval: nil,
        completedReleaseCount: 0
    )
    @State private var showingTimingHelp = false

    var body: some View {
        Group {
            if let dashboard {
                List {
                    if let issue = dashboard.sectionIssues[.releases] {
                        Section {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                    }

                    if let current = dashboard.currentRelease {
                        Section("Current Release") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Version \(current.version)").font(.title2.bold())
                                    Spacer()
                                    ReleaseStatusLabel(state: current.state)
                                }
                                if let submissionState = current.reviewSubmissionState {
                                    LabeledContent("Review submission", value: submissionState.displayStatus)
                                }
                            }
                            ReleaseTimelineView(release: current, observations: observations)
                        }
                    } else if dashboard.sectionIssues[.releases] == nil {
                        ContentUnavailableView(
                            "No Releases",
                            systemImage: "shippingbox",
                            description: Text("Apple returned no App Store versions for this app.")
                        )
                    }

                    if statistics.completedReleaseCount > 0 {
                        Section {
                            if let value = statistics.averageWaiting {
                                LabeledContent("Average observed wait", value: DisplayFormatters.duration(value))
                            }
                            if let value = statistics.averageInReview {
                                LabeledContent("Average observed review", value: DisplayFormatters.duration(value))
                            }
                            if let value = statistics.fastestApproval {
                                LabeledContent("Fastest observed approval", value: DisplayFormatters.duration(value))
                            }
                            if let value = statistics.longestApproval {
                                LabeledContent("Longest observed approval", value: DisplayFormatters.duration(value))
                            }
                        } header: {
                            HStack {
                                Text("Observed Timing")
                                Spacer()
                                Button("About timing", systemImage: "info.circle") { showingTimingHelp = true }
                                    .labelStyle(.iconOnly)
                            }
                        } footer: {
                            Text("Based on \(statistics.completedReleaseCount) locally observed \(statistics.completedReleaseCount == 1 ? "release" : "releases").")
                        }
                    }

                    if !dashboard.releases.isEmpty {
                        Section("All Versions") {
                            ForEach(dashboard.releases) { release in
                                ReleaseRow(release: release)
                            }
                        }
                    }
                }
                .refreshable { await model.refresh() }
                .task(id: dashboard.currentRelease?.id) {
                    if let releaseID = dashboard.currentRelease?.id {
                        observations = await model.observations(for: releaseID)
                    }
                    statistics = await model.statistics(for: dashboard.id)
                }
            } else {
                ChooseAppView()
            }
        }
        .navigationTitle("Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { AppContextToolbar(dashboards: model.dashboards, selectedAppID: $selectedAppID) }
        .sheet(isPresented: $showingTimingHelp) {
            NavigationStack {
                List {
                    Section("Apple Timestamp") {
                        Text("Apple provides the review submission date. ReviewBar labels this timestamp directly.")
                    }
                    Section("Observed by ReviewBar") {
                        Text("Apple’s read API does not provide a timestamp for every state transition. ReviewBar records when this device first sees a new state, so the actual transition may have happened earlier.")
                    }
                    Section("Statistics") {
                        Text("Only completed transitions observed on this device are included. They are approximate and disappear if local history is cleared.")
                    }
                }
                .navigationTitle("About Release Timing")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct ReleaseTimelineView: View {
    let release: AppRelease
    let observations: [ReleaseObservation]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let submitted = release.submittedDate {
                TimelineEvent(
                    title: "Submitted",
                    detail: DisplayFormatters.dateTime(submitted),
                    source: "Apple timestamp",
                    symbol: "paperplane.fill",
                    tint: .blue
                )
            }
            ForEach(observations) { observation in
                TimelineEvent(
                    title: "First observed \(observation.state.title)",
                    detail: DisplayFormatters.dateTime(observation.observedAt),
                    source: observation.source.label,
                    symbol: observation.state.symbol,
                    tint: observation.state.tint
                )
            }
            if observations.isEmpty && release.submittedDate == nil {
                Text("ReviewBar will build a device-local timeline as it observes state changes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TimelineEvent: View {
    let title: String
    let detail: String
    let source: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text(source).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ReleaseRow: View {
    let release: AppRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Version \(release.version)").font(.headline)
                Spacer()
                ReleaseStatusLabel(state: release.state)
            }
            HStack(spacing: 8) {
                Text(release.platform.label)
                if let created = release.createdDate {
                    Text("Created \(DisplayFormatters.relative(created))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

