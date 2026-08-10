import SwiftUI

struct BuildsView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @State private var selectedPlatform: AppRelease.Platform?
    @State private var filter: BuildFilter = .all
    @State private var sort: BuildSort = .newest
    @State private var query = ""
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
                    if let issue = dashboard.sectionIssues[.builds] {
                        Section {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                    }
                    if visibleBuilds.isEmpty, dashboard.sectionIssues[.builds] == nil || !dashboard.builds.isEmpty {
                        let platformBuilds = dashboard.builds.filter { selectedPlatform == nil || $0.platform == selectedPlatform }
                        ContentUnavailableView {
                            Label(platformBuilds.isEmpty ? "No Builds for \(selectedPlatform?.label ?? "This App")" : "No Matching Builds", systemImage: "hammer")
                        } description: {
                            Text(platformBuilds.isEmpty
                                 ? "Apple returned no builds for the selected platform."
                                 : "Clear the search or choose a different build filter.")
                        } actions: {
                            if !platformBuilds.isEmpty, filter != .all || !query.isEmpty {
                                Button("Clear Search and Filter") {
                                    query = ""
                                    filter = .all
                                }
                            }
                        }
                    } else {
                        ForEach(groupedVersions, id: \.version) { group in
                            Section(group.version) {
                                ForEach(group.builds) { build in
                                    BuildRow(build: build)
                                }
                            }
                        }
                        Section {
                            Text("ReviewBar follows Apple’s complete paginated build history for this app.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .refreshable { await model.refresh() }
                .onChange(of: dashboard.availablePlatforms, initial: true) { _, platforms in
                    if selectedPlatform == nil || !platforms.contains(selectedPlatform ?? .unknown) {
                        selectedPlatform = dashboard.preferredPlatform
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Sort and Filter", systemImage: "line.3.horizontal.decrease") {
                            Picker("Filter", selection: $filter) {
                                ForEach(BuildFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Picker("Sort", selection: $sort) {
                                ForEach(BuildSort.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                    }
                }
            } else {
                ChooseAppView()
            }
        }
        .navigationTitle("Builds")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search build or version")
    }

    private var visibleBuilds: [BuildInfo] {
        guard let dashboard else { return [] }
        let filtered = dashboard.builds.filter { build in
            guard selectedPlatform == nil || build.platform == selectedPlatform else { return false }
            guard query.isEmpty
                    || build.buildNumber.localizedStandardContains(query)
                    || (build.version?.localizedStandardContains(query) == true) else { return false }
            switch filter {
            case .all: return true
            case .processing: return !build.expired && build.processingState == .processing
            case .ready: return !build.expired && build.processingState == .valid
            case .failed: return build.processingState == .failed || build.processingState == .invalid
            case .expired: return build.expired
            case .expiringSoon:
                guard !build.expired, let expiration = build.expirationDate else { return false }
                return expiration.timeIntervalSinceNow <= 14 * 86_400
            }
        }
        switch sort {
        case .newest:
            return filtered.sorted { ($0.uploadedDate ?? .distantPast) > ($1.uploadedDate ?? .distantPast) }
        case .oldest:
            return filtered.sorted { ($0.uploadedDate ?? .distantFuture) < ($1.uploadedDate ?? .distantFuture) }
        case .expirySoon:
            return filtered.sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
        }
    }

    private var groupedVersions: [(version: String, builds: [BuildInfo])] {
        let grouped = Dictionary(grouping: visibleBuilds) { $0.version ?? "Unknown Version" }
        let order = Dictionary(
            visibleBuilds.enumerated().map { (($0.element.version ?? "Unknown Version"), $0.offset) },
            uniquingKeysWith: min
        )
        return grouped.map { (version: $0.key, builds: $0.value) }
            .sorted { order[$0.version, default: .max] < order[$1.version, default: .max] }
    }
}

private enum BuildFilter: CaseIterable, Equatable {
    case all, processing, ready, failed, expired, expiringSoon

    var title: String {
        switch self {
        case .all: "All Builds"
        case .processing: "Processing"
        case .ready: "Ready"
        case .failed: "Failed or Invalid"
        case .expired: "Expired"
        case .expiringSoon: "Expiring Soon"
        }
    }
}

private enum BuildSort: CaseIterable {
    case newest, oldest, expirySoon

    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .expirySoon: "Expiry Soon"
        }
    }
}

private struct BuildRow: View {
    let build: BuildInfo
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    buildTitle
                    BuildStatusLabel(build: build)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    buildTitle
                    Spacer()
                    BuildStatusLabel(build: build)
                }
            }
            if let uploaded = build.uploadedDate {
                Text("Uploaded \(DisplayFormatters.relative(uploaded)) · \(DisplayFormatters.dateTime(uploaded))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let selectedVersion = build.selectedForAppStoreVersion {
                Label("Selected for App Store version \(selectedVersion)", systemImage: "app.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let audienceType = build.audienceType {
                LabeledContent("Audience", value: audienceType.displayStatus)
                    .font(.caption)
            }
            if let state = build.internalBetaState {
                LabeledContent("Internal TestFlight", value: state.displayStatus)
                    .font(.caption)
            }
            if let state = build.externalBetaState, state != "NOT_APPLICABLE" {
                LabeledContent("External TestFlight", value: state.displayStatus)
                    .font(.caption)
            }
            if let state = build.betaReviewState {
                LabeledContent("Beta review", value: state.displayStatus)
                    .font(.caption)
            }
            if let expiration = build.expirationDate {
                if !build.expired, expiration.timeIntervalSinceNow < 14 * 86_400 {
                    Label {
                        Text("Expires \(DisplayFormatters.relative(expiration)) · \(DisplayFormatters.dateTime(expiration))")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                } else {
                    Text(build.expired
                         ? "Expired \(DisplayFormatters.dateTime(expiration))"
                         : "Expires \(DisplayFormatters.relative(expiration)) · \(DisplayFormatters.dateTime(expiration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var buildTitle: some View {
        Text(build.version.map { "\($0) (\(build.buildNumber))" } ?? "Build \(build.buildNumber)")
            .font(.headline)
    }
}
