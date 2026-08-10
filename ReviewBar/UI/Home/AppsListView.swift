import SwiftUI

struct AppsListView: View {
    let model: AppModel
    @Binding var selectedAppID: String?
    let onOpenApp: (String) -> Void
    @State private var query = ""
    @State private var showingSettings = false

    var body: some View {
        @Bindable var preferences = model.preferences
        Group {
            if model.dashboards.isEmpty && !model.isRefreshing, let issue = model.lastRefreshIssue {
                ContentUnavailableView {
                    Label(issue.title, systemImage: issue.kind == .offline ? "wifi.slash" : "exclamationmark.triangle")
                } description: {
                    Text(issue.message)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            } else if model.dashboards.isEmpty && !model.isRefreshing {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "square.grid.2x2")
                } description: {
                    Text("Apple returned no apps visible to this API key. Check the key’s user and app access.")
                } actions: {
                    Button("Refresh") { Task { await model.refresh() } }
                }
            } else {
                List {
                    if model.showingCachedData {
                        DataStatusBanner(lastUpdated: model.lastUpdated, issue: model.lastRefreshIssue)
                    }

                    if filteredDashboards.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Apps", systemImage: "magnifyingglass")
                        } description: {
                            Text("Clear the search or choose a different activity filter.")
                        } actions: {
                            Button("Clear Search and Filter") {
                                query = ""
                                model.preferences.appActivityFilter = .all
                            }
                        }
                    } else {
                        ForEach(filteredDashboards) { dashboard in
                            Button {
                                onOpenApp(dashboard.id)
                            } label: {
                                AppRowView(
                                    dashboard: dashboard,
                                    isFavorite: model.preferences.isFavorite(appID: dashboard.id),
                                    unreadCount: dashboard.reviews.lazy.filter {
                                        model.unreadReviewIDs.contains($0.id)
                                    }.count
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the app overview")
                            .swipeActions(edge: .leading) {
                                Button(
                                    model.preferences.isFavorite(appID: dashboard.id) ? "Unfavorite" : "Favorite",
                                    systemImage: model.preferences.isFavorite(appID: dashboard.id) ? "star.slash" : "star"
                                ) {
                                    model.preferences.toggleFavorite(appID: dashboard.id)
                                }
                                .tint(.yellow)
                            }
                        }

                        if model.dashboards.count > 1 {
                            PortfolioSummaryView(
                                appCount: model.dashboards.count,
                                favoriteCount: model.dashboards.count(where: {
                                    model.preferences.isFavorite(appID: $0.id)
                                }),
                                attentionCount: model.dashboards.count(where: { $0.requiresAttention }),
                                unreadReviewCount: model.unreadReviewIDs.count,
                                lastUpdated: model.lastUpdated
                            )
                        }
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
                } else if !model.dashboards.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                }
                Menu("Sort and Filter", systemImage: preferences.appActivityFilter == .all && preferences.appListSort == .name ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") {
                    Picker("Sort", selection: $preferences.appListSort) {
                        ForEach(AppListSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Activity", selection: $preferences.appActivityFilter) {
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
            switch model.preferences.appActivityFilter {
            case .all: matchesFilter = true
            case .favorites: matchesFilter = model.preferences.isFavorite(appID: dashboard.id)
            case .needsAttention: matchesFilter = dashboard.requiresAttention
            case .inReview: matchesFilter = dashboard.releases.contains { $0.state == .inReview }
            case .processing: matchesFilter = dashboard.builds.contains { $0.processingState == .processing }
            case .newReviews: matchesFilter = dashboard.reviews.contains { model.unreadReviewIDs.contains($0.id) }
            }
            return matchesSearch && matchesFilter
        }
        switch model.preferences.appListSort {
        case .favoritesFirst:
            return matching.sorted {
                let lhsFavorite = model.preferences.isFavorite(appID: $0.id)
                let rhsFavorite = model.preferences.isFavorite(appID: $1.id)
                if lhsFavorite != rhsFavorite { return lhsFavorite }
                return $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
            }
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
        ([dashboard.newestReview?.createdDate]
            + dashboard.builds.map(\.uploadedDate)
            + dashboard.releases.map(\.submittedDate))
            .compactMap { $0 }
            .max() ?? .distantPast
    }

    private func unreadCount(_ dashboard: AppDashboard) -> Int {
        dashboard.reviews.lazy.filter { model.unreadReviewIDs.contains($0.id) }.count
    }
}
