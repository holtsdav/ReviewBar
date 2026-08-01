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

struct AppSelectionPicker: View {
    let dashboards: [AppDashboard]
    @Binding var selection: String?
    let includesAllApps: Bool

    init(dashboards: [AppDashboard], selection: Binding<String?>, includesAllApps: Bool = false) {
        self.dashboards = dashboards
        _selection = selection
        self.includesAllApps = includesAllApps
    }

    var body: some View {
        Picker("App", selection: selectedApp) {
            if includesAllApps {
                Text("All Apps").tag("")
            }
            ForEach(dashboards) { dashboard in
                Text(verbatim: dashboard.app.name).tag(dashboard.id)
            }
        }
        .pickerStyle(.menu)
    }

    private var selectedApp: Binding<String> {
        Binding(
            get: { selection ?? (includesAllApps ? "" : dashboards.first?.id ?? "") },
            set: { selection = $0.isEmpty ? nil : $0 }
        )
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
