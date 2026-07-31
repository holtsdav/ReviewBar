import SwiftUI

struct HomeView: View {
    let model: AppModel
    @State private var selectedTab: DashboardTab = .apps
    @State private var selectedAppID: String?

    init(model: AppModel) {
        self.model = model
        _selectedAppID = State(initialValue: UserDefaults.standard.string(forKey: "ReviewBar.selectedAppID"))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                AppsListView(
                    model: model,
                    selectedAppID: $selectedAppID,
                    selectedTab: $selectedTab
                )
            }
            .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            .tag(DashboardTab.apps)

            NavigationStack {
                AppOverviewView(
                    model: model,
                    dashboard: selectedDashboard,
                    selectedAppID: $selectedAppID,
                    selectedTab: $selectedTab
                )
            }
            .tabItem { Label("Overview", systemImage: "rectangle.grid.1x2") }
            .tag(DashboardTab.overview)

            NavigationStack {
                ReleasesView(model: model, dashboard: selectedDashboard, selectedAppID: $selectedAppID)
            }
            .tabItem { Label("Releases", systemImage: "point.3.connected.trianglepath.dotted") }
            .tag(DashboardTab.releases)

            NavigationStack {
                ReviewsView(model: model, dashboard: selectedDashboard, selectedAppID: $selectedAppID)
            }
            .tabItem { Label("Reviews", systemImage: "star.bubble") }
            .badge(unreadCount)
            .tag(DashboardTab.reviews)

            NavigationStack {
                BuildsView(model: model, dashboard: selectedDashboard, selectedAppID: $selectedAppID)
            }
            .tabItem { Label("Builds", systemImage: "hammer") }
            .tag(DashboardTab.builds)
        }
        .onChange(of: selectedAppID) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "ReviewBar.selectedAppID")
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
        guard let selectedDashboard else { return 0 }
        return selectedDashboard.reviews.lazy.filter { model.unreadReviewIDs.contains($0.id) }.count
    }
}

enum DashboardTab: Hashable {
    case apps
    case overview
    case releases
    case reviews
    case builds
}

#Preview("Demo Dashboard") {
    HomeView(model: .preview())
}
