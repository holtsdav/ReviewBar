import SwiftUI

struct AppContextToolbar: ToolbarContent {
    let dashboards: [AppDashboard]
    @Binding var selectedAppID: String?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
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
                HStack(spacing: 4) {
                    Text(dashboards.first(where: { $0.id == selectedAppID })?.app.name ?? "Choose App")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Selected app")
            .accessibilityValue(dashboards.first(where: { $0.id == selectedAppID })?.app.name ?? "None")
        }
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

