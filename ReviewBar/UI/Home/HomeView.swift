import SwiftUI

struct HomeView: View {
    let model: AppModel
    @State private var selectedTab: DashboardTab = .apps
    @State private var selectedAppID: String?
    @State private var appsPath = NavigationPath()
    @State private var reviewsPath = NavigationPath()
    @State private var analyticsPath = NavigationPath()

    init(model: AppModel) {
        self.model = model
        _selectedAppID = State(initialValue: UserDefaults.standard.string(forKey: "ReviewBar.selectedAppID"))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Apps", systemImage: "square.grid.2x2", value: .apps) {
                NavigationStack(path: $appsPath) {
                    AppsListView(
                        model: model,
                        selectedAppID: $selectedAppID,
                        onOpenApp: { appID in
                            selectedAppID = appID
                            appsPath.append(AppsRoute.overview)
                        }
                    )
                    .navigationDestination(for: AppsRoute.self) { route in
                        switch route {
                        case .overview:
                            AppOverviewView(
                                model: model,
                                dashboard: selectedDashboard,
                                selectedAppID: $selectedAppID,
                                onOpenReviews: {
                                    reviewsPath = NavigationPath()
                                    selectedTab = .reviews
                                },
                                onOpenAnalytics: {
                                    analyticsPath = NavigationPath()
                                    selectedTab = .analytics
                                }
                            )
                            .navigationDestination(for: OverviewRoute.self) { route in
                                switch route {
                                case .releaseHistory(let platform):
                                    ReleasesView(model: model, dashboard: selectedDashboard, initialPlatform: platform)
                                case .builds(let platform):
                                    BuildsView(model: model, dashboard: selectedDashboard, initialPlatform: platform)
                                }
                            }
                        }
                    }
                }
            }

            Tab("Reviews", systemImage: "star.bubble", value: .reviews) {
                NavigationStack(path: $reviewsPath) {
                    ReviewsView(model: model, isActive: selectedTab == .reviews)
                }
            }
            .badge(unreadCount)

            Tab("Analytics", systemImage: "chart.xyaxis.line", value: .analytics) {
                NavigationStack(path: $analyticsPath) {
                    AnalyticsView(
                        model: model,
                        dashboard: selectedDashboard,
                        selectedAppID: $selectedAppID,
                        isActive: selectedTab == .analytics
                    )
                }
            }
        }
        .onChange(of: selectedAppID) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "ReviewBar.selectedAppID")
            reviewsPath = NavigationPath()
            analyticsPath = NavigationPath()
        }
        .onChange(of: model.dashboards.map(\.id), initial: true) { _, ids in
            if selectedAppID == nil || !ids.contains(selectedAppID ?? "") {
                selectedAppID = ids.first
            }
        }
    }

    private var selectedDashboard: AppDashboard? {
        model.dashboards.first { $0.id == selectedAppID }
    }

    private var unreadCount: Int {
        model.unreadReviewIDs.count
    }
}

enum DashboardTab: String, Hashable {
    case apps, reviews, analytics
}

private enum AppsRoute: Hashable {
    case overview
}

enum OverviewRoute: Hashable {
    case releaseHistory(AppRelease.Platform?)
    case builds(AppRelease.Platform?)
}

#Preview("Dashboard") {
    HomeView(model: .preview())
}
