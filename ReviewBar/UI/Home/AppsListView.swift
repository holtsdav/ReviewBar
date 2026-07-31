import SwiftUI

struct AppsListView: View {
    let model: AppModel
    @Binding var selectedAppID: String?
    @Binding var selectedTab: DashboardTab
    @State private var query = ""
    @State private var sort = AppSort.name
    @State private var filter = AppActivityFilter.all
    @State private var showingSettings = false

    var body: some View {
        Group {
            if model.dashboards.isEmpty && !model.isRefreshing {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "square.grid.2x2")
                } description: {
                    Text(model.source == .demo
                         ? "This demo scenario has no apps."
                         : "Apple returned no apps visible to this API key. Check the key’s user and app access.")
                } actions: {
                    Button("Refresh") { Task { await model.refresh() } }
                }
            } else {
                List {
                    if model.showingCachedData, let lastUpdated = model.lastUpdated {
                        CachedDataBanner(lastUpdated: lastUpdated)
                    }

                    ForEach(filteredDashboards) { dashboard in
                        Button {
                            selectedAppID = dashboard.id
                            selectedTab = .overview
                        } label: {
                            AppRowView(
                                dashboard: dashboard,
                                unreadCount: dashboard.reviews.lazy.filter {
                                    model.unreadReviewIDs.contains($0.id)
                                }.count
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the app overview")
                    }
                }
                .refreshable { await model.refresh() }
                .overlay {
                    if model.isRefreshing && model.dashboards.isEmpty {
                        ProgressView("Loading apps…")
                    }
                }
            }
        }
        .navigationTitle("Apps")
        .searchable(text: $query, prompt: "Search apps")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.isRefreshing && !model.dashboards.isEmpty {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                }
                Menu("Sort and Filter", systemImage: "line.3.horizontal.decrease") {
                    Picker("Sort", selection: $sort) {
                        ForEach(AppSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Activity", selection: $filter) {
                        ForEach(AppActivityFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Button("Settings", systemImage: "gear") { showingSettings = true }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
    }

    private var filteredDashboards: [AppDashboard] {
        let matching = model.dashboards.filter { dashboard in
            let matchesSearch = query.isEmpty
                || dashboard.app.name.localizedStandardContains(query)
                || dashboard.app.bundleID.localizedStandardContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .inReview: matchesFilter = dashboard.currentRelease?.state == .inReview
            case .processing: matchesFilter = dashboard.latestBuild?.processingState == .processing
            case .newReviews: matchesFilter = dashboard.reviews.contains { model.unreadReviewIDs.contains($0.id) }
            }
            return matchesSearch && matchesFilter
        }
        switch sort {
        case .name:
            return matching.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        case .recentActivity:
            return matching.sorted { activityDate($0) > activityDate($1) }
        case .newActivity:
            return matching.sorted {
                unreadCount($0) == unreadCount($1)
                    ? activityDate($0) > activityDate($1)
                    : unreadCount($0) > unreadCount($1)
            }
        }
    }

    private func activityDate(_ dashboard: AppDashboard) -> Date {
        [dashboard.newestReview?.createdDate, dashboard.latestBuild?.uploadedDate, dashboard.currentRelease?.submittedDate]
            .compactMap { $0 }
            .max() ?? .distantPast
    }

    private func unreadCount(_ dashboard: AppDashboard) -> Int {
        dashboard.reviews.lazy.filter { model.unreadReviewIDs.contains($0.id) }.count
    }
}

private enum AppSort: CaseIterable {
    case name, recentActivity, newActivity

    var title: String {
        switch self {
        case .name: "Name"
        case .recentActivity: "Recent Activity"
        case .newActivity: "New Activity"
        }
    }
}

private enum AppActivityFilter: CaseIterable {
    case all, inReview, processing, newReviews

    var title: String {
        switch self {
        case .all: "All Apps"
        case .inReview: "In Review"
        case .processing: "Processing Builds"
        case .newReviews: "New Reviews"
        }
    }
}

private struct CachedDataBanner: View {
    let lastUpdated: Date

    var body: some View {
        Label {
            Text("Showing saved data from \(DisplayFormatters.dateTime(lastUpdated))")
                .font(.footnote)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

