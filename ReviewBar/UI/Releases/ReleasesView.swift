import SwiftUI

struct ReleasesView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @State private var selectedPlatform: AppRelease.Platform?
    @State private var observations: [ReleaseObservation] = []
    @State private var statistics = ReleaseStatistics(
        averageWaiting: nil,
        averageInReview: nil,
        fastestApproval: nil,
        longestApproval: nil,
        completedReleaseCount: 0
    )
    @State private var showingTimingHelp = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: AppModel, dashboard: AppDashboard?, initialPlatform: AppRelease.Platform?) {
        self.model = model
        self.dashboard = dashboard
        _selectedPlatform = State(initialValue: initialPlatform ?? dashboard?.preferredPlatform)
    }

    var body: some View {
        Group {
            if let dashboard {
                List {
                    SelectedAppHeader(name: dashboard.app.name)
                    Section {
                        PlatformPicker(platforms: dashboard.availablePlatforms, selection: $selectedPlatform)
                    }
                    if model.showingCachedData {
                        DataStatusBanner(lastUpdated: model.lastUpdated, issue: model.lastRefreshIssue)
                    }
                    if let issue = dashboard.sectionIssues[.releases] {
                        Section {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                    }

                    if let current = currentRelease {
                        Section("Current Release") {
                            VStack(alignment: .leading, spacing: 10) {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Version \(current.version)").font(.title2.bold())
                                        ReleaseStatusLabel(state: current.state)
                                    }
                                } else {
                                    HStack {
                                        Text("Version \(current.version)").font(.title2.bold())
                                        Spacer()
                                        ReleaseStatusLabel(state: current.state)
                                    }
                                }
                                if let submissionState = current.reviewSubmissionState {
                                    LabeledContent("Review submission", value: submissionState.displayStatus)
                                }
                            }
                            ReleaseProgressView(release: current, observations: observations)
                            ReleaseTimelineView(release: current, observations: observations)
                        }
                    } else if dashboard.sectionIssues[.releases] == nil {
                        ContentUnavailableView(
                            "No Releases for \(selectedPlatform?.label ?? "This App")",
                            systemImage: "shippingbox",
                            description: Text("Apple returned no App Store versions for the selected platform.")
                        )
                    }

                    if statistics.completedReleaseCount > 0 {
                        Section {
                            if let value = statistics.averageWaiting {
                                LabeledContent("Average recorded wait", value: DisplayFormatters.duration(value))
                            }
                            if let value = statistics.averageInReview {
                                LabeledContent("Average recorded review", value: DisplayFormatters.duration(value))
                            }
                            if let value = statistics.fastestApproval {
                                LabeledContent("Fastest recorded approval", value: DisplayFormatters.duration(value))
                            }
                            if let value = statistics.longestApproval {
                                LabeledContent("Longest recorded approval", value: DisplayFormatters.duration(value))
                            }
                        } header: {
                            HStack {
                                Text("All-Platform Release Timing")
                                Spacer()
                                Button("About timing", systemImage: "info.circle") { showingTimingHelp = true }
                                    .labelStyle(.iconOnly)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                        } footer: {
                            Text("Based on \(statistics.completedReleaseCount) completed \(statistics.completedReleaseCount == 1 ? "timeline" : "timelines"). Exact Apple timestamps are preferred; local observations remain lower-bound estimates.")
                        }
                    }

                    if !scopedReleases.isEmpty {
                        Section("All Versions") {
                            ForEach(scopedReleases) { release in
                                ReleaseRow(release: release)
                            }
                        }
                    }
                }
                .refreshable { await model.refresh() }
                .onChange(of: dashboard.availablePlatforms, initial: true) { _, platforms in
                    if selectedPlatform == nil || !platforms.contains(selectedPlatform ?? .unknown) {
                        selectedPlatform = dashboard.preferredPlatform
                    }
                }
                .task(id: releaseTaskID(for: dashboard)) {
                    if let releaseID = currentRelease?.id {
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
        .sheet(isPresented: $showingTimingHelp) {
            NavigationStack {
                List {
                    Section("Apple Timestamp") {
                        Text("Apple provides the review submission date. ReviewBar labels this timestamp directly.")
                    }
                    Section("Apple Webhook Timestamp") {
                        Text("When real-time updates are enabled, supported Apple webhook events can provide the exact state-transition time. ReviewBar labels those events as authoritative Apple webhook timestamps.")
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
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingTimingHelp = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func releaseTaskID(for dashboard: AppDashboard) -> String {
        let release = currentRelease
        return "\(release?.id ?? "none")|\(release?.state.rawValue ?? "none")|\(dashboard.fetchedAt.timeIntervalSince1970)"
    }

    private var scopedReleases: [AppRelease] {
        guard let dashboard, let selectedPlatform else { return dashboard?.releases ?? [] }
        return dashboard.releases.filter { $0.platform == selectedPlatform }
    }

    private var currentRelease: AppRelease? {
        dashboard?.currentRelease(in: selectedPlatform)
    }
}

private struct ReleaseProgressView: View {
    let release: AppRelease
    let observations: [ReleaseObservation]

    private let phases = ["Submitted", "Waiting for Review", "In Review", "Approved / Distribution"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let currentPhase {
                ForEach(phases.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(for: index, currentPhase: currentPhase))
                            .foregroundStyle(index == currentPhase ? release.state.tint : index < currentPhase ? .green : .secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phases[index])
                                .font(.subheadline.weight(index == currentPhase ? .semibold : .regular))
                            if index == currentPhase, let currentDetail {
                                Text(currentDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(phases[index])
                    .accessibilityValue(accessibilityValue(for: index, currentPhase: currentPhase))
                }
            } else {
                Label(release.state.title, systemImage: release.state.symbol)
                    .font(.subheadline.weight(.semibold))
                Text(specialStateExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var currentPhase: Int? {
        switch release.state {
        case .waitingForReview: 1
        case .inReview: 2
        case .pendingAppleRelease, .pendingDeveloperRelease,
             .processingForDistribution, .readyForDistribution: 3
        case .prepareForSubmission, .readyForReview, .accepted,
             .waitingForExportCompliance, .rejected, .developerRejected,
             .metadataRejected, .invalidBinary, .replacedWithNewVersion: nil
        default: release.submittedDate == nil ? nil : 0
        }
    }

    private var specialStateExplanation: String {
        switch release.state {
        case .accepted:
            "Apple accepted this submission item, but the version is not yet Ready for Distribution."
        case .prepareForSubmission, .readyForReview:
            "This version has not entered the review queue."
        case .waitingForExportCompliance:
            "Distribution is paused for export-compliance review."
        case .replacedWithNewVersion:
            "A newer version replaced this release."
        default:
            release.state.requiresAttention
                ? "The normal release path is paused and needs attention in App Store Connect."
                : "This Apple state does not map to a linear review phase, so ReviewBar does not infer one."
        }
    }

    private var currentDetail: String? {
        if let observation = observations.last(where: { $0.state == release.state }) {
            let duration = DisplayFormatters.duration(Date.now.timeIntervalSince(observation.observedAt))
            switch observation.source {
            case .appleWebhook:
                return "Apple webhook transition: \(duration) ago."
            case .apple:
                return "Apple API timestamp: \(DisplayFormatters.dateTime(observation.observedAt))."
            case .localObservation:
                return "Observed in this state for at least \(duration)."
            }
        }
        if let submittedDate = release.submittedDate {
            return "Apple submission timestamp: \(DisplayFormatters.dateTime(submittedDate))."
        }
        return nil
    }

    private func symbol(for index: Int, currentPhase: Int) -> String {
        if index < currentPhase { return "checkmark.circle.fill" }
        if index == currentPhase { return "circle.inset.filled" }
        return "circle"
    }

    private func accessibilityValue(for index: Int, currentPhase: Int) -> String {
        if index < currentPhase { return "Completed" }
        if index == currentPhase { return "Current" }
        return "Pending"
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
                    title: timelineTitle(for: observation),
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

    private func timelineTitle(for observation: ReleaseObservation) -> String {
        switch observation.source {
        case .appleWebhook: "Changed to \(observation.state.title)"
        case .apple: "Apple recorded \(observation.state.title)"
        case .localObservation: "First observed \(observation.state.title)"
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Version \(release.version)").font(.headline)
                    ReleaseStatusLabel(state: release.state)
                }
            } else {
                HStack {
                    Text("Version \(release.version)").font(.headline)
                    Spacer()
                    ReleaseStatusLabel(state: release.state)
                }
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) { releaseMetadata }
                } else {
                    HStack(spacing: 8) { releaseMetadata }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var releaseMetadata: some View {
        Text(release.platform.label)
        if let created = release.createdDate {
            Text("Created \(DisplayFormatters.relative(created))")
                }
    }
}
