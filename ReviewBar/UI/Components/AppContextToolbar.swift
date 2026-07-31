import SwiftUI

struct AppContextToolbar: ToolbarContent {
    let dashboards: [AppDashboard]
    @Binding var selectedAppID: String?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(dashboards) { dashboard in
                    Button {
                        selectedAppID = dashboard.id
                    } label: {
                        if selectedAppID == dashboard.id {
                            Label(dashboard.app.name, systemImage: "checkmark")
                        } else {
                            Text(dashboard.app.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityLabel("Selected app")
            .accessibilityValue(selectedAppName)
        }
    }

    private var selectedAppName: String {
        dashboards.first(where: { $0.id == selectedAppID })?.app.name ?? "None"
    }
}

struct SelectedAppHeader: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.title2.bold())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ChooseAppView: View {
    var body: some View {
        ContentUnavailableView(
            "Choose an App",
            systemImage: "square.grid.2x2",
            description: Text("Select an app from the Apps tab to view this dashboard.")
        )
    }
}
