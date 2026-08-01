import Charts
import SwiftUI

struct AnalyticsView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @State private var range: AnalyticsRange = .sevenDays
    @State private var showingMethodology = false

    var body: some View {
        Group {
            if let dashboard {
                List {
                    SelectedAppHeader(name: dashboard.app.name)
                    Section {
                        Picker("Time Range", selection: $range) {
                            ForEach(AnalyticsRange.allCases) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    stateContent(model.analyticsState(for: dashboard.id), appID: dashboard.id)
                }
                .refreshable { await model.loadAnalytics(appID: dashboard.id, force: true) }
                .task(id: dashboard.id) {
                    await model.prepareAnalytics(appID: dashboard.id)
                    await model.loadAnalytics(appID: dashboard.id)
                }
            } else {
                ChooseAppView()
            }
        }
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppContextToolbar(dashboards: model.dashboards, selectedAppID: $selectedAppID)
            ToolbarItem(placement: .topBarTrailing) {
                Button("About Analytics", systemImage: "info.circle") { showingMethodology = true }
            }
        }
        .sheet(isPresented: $showingMethodology) { AnalyticsMethodologyView() }
    }

    @ViewBuilder
    private func stateContent(_ state: AnalyticsLoadState, appID: String) -> some View {
        switch state {
        case .idle:
            Section { ProgressView("Loading Analytics…") }
        case .loading(let cached):
            if let cached {
                analyticsContent(cached, refreshing: true)
            } else {
                Section { ProgressView("Downloading Apple Analytics reports…") }
            }
        case .available(let dataset):
            analyticsContent(dataset, refreshing: false)
        case .notEnabled:
            Section {
                ContentUnavailableView {
                    Label("Analytics Not Enabled", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Apple hasn't generated Analytics reports for this app. An Admin API key is required to create the initial ongoing report request.")
                } actions: {
                    Button("Enable Analytics") { Task { await model.enableAnalytics(appID: appID) } }
                }
            }
        case .generating:
            Section {
                ContentUnavailableView {
                    Label("Apple Is Preparing Reports", systemImage: "clock")
                } description: {
                    Text("Initial Analytics data normally takes 24–48 hours. Pull to refresh later; Overview and other data remain available.")
                }
            }
        case .stoppedDueToInactivity:
            Section {
                ContentUnavailableView {
                    Label("Report Generation Stopped", systemImage: "pause.circle")
                } description: {
                    Text("Apple stopped this request after a period of inactivity. An Admin can create a new ongoing request.")
                } actions: {
                    Button("Create New Request") { Task { await model.enableAnalytics(appID: appID) } }
                }
            }
        case .permissionRequired(let message):
            Section {
                ContentUnavailableView {
                    Label("Analytics Permission Required", systemImage: "lock")
                } description: { Text(message) }
            }
        case .failed(let message, let cached):
            if let cached {
                Section { Label(message, systemImage: "exclamationmark.triangle") }
                analyticsContent(cached, refreshing: false)
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Analytics Unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) }
                }
            }
        }
    }

    @ViewBuilder
    private func analyticsContent(_ dataset: AnalyticsDataset, refreshing: Bool) -> some View {
        let summary = dataset.summary(range: range)
        Section {
            if let end = summary.coverageEnd {
                LabeledContent("Data through", value: end.date.formatted(date: .abbreviated, time: .omitted))
            }
            if let start = summary.coverageStart, let end = summary.coverageEnd {
                LabeledContent("Available coverage", value: "\(start.iso8601) – \(end.iso8601)")
            }
            if refreshing {
                Label("Updating from Apple…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Analytics is delayed and privacy-protected. The date above comes from report rows, not Apple's processing date.")
        }

        if let downloads = downloadChartPoints(summary), !downloads.isEmpty {
            Section("Downloads Trend") {
                Chart(downloads) { point in
                    LineMark(
                        x: .value("Date", point.day.date),
                        y: .value("Downloads", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("Date", point.day.date),
                        y: .value("Downloads", point.value)
                    )
                    .foregroundStyle(.tint.opacity(0.12))
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(minHeight: 170)
                .accessibilityLabel("Downloads over \(range.title)")
            }
        }

        ForEach(AnalyticsMetricCategory.allCases, id: \.self) { category in
            let metrics = visibleMetrics(in: category, summary: summary)
            if !metrics.isEmpty || (category == .downloads && summary.totalDownloads != .notAvailable) {
                Section(category.rawValue) {
                    if category == .downloads {
                        AnalyticsMetricRow(title: "Total Downloads", value: summary.totalDownloads, unit: .count)
                    }
                    ForEach(metrics, id: \.self) { metric in
                        AnalyticsMetricRow(
                            title: metric.title,
                            value: summary.values[metric] ?? .notAvailable,
                            unit: metric.unit
                        )
                    }
                }
            }
        }

        if !summary.warnings.isEmpty {
            Section {
                ForEach(summary.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            } header: {
                Text("Partial Data")
            } footer: {
                Text("A report schema or download can fail independently without hiding valid metrics from other reports.")
            }
        }
    }

    private func visibleMetrics(in category: AnalyticsMetricCategory, summary: AnalyticsSummary) -> [AnalyticsMetricID] {
        AnalyticsMetricID.allCases.filter {
            $0.category == category && summary.values[$0] != .notAvailable
        }
    }

    private func downloadChartPoints(_ summary: AnalyticsSummary) -> [AnalyticsMetricPoint]? {
        let first = summary.chartPoints[.firstTimeDownloads] ?? []
        let again = summary.chartPoints[.redownloads] ?? []
        guard !first.isEmpty || !again.isEmpty else { return nil }
        var byDay: [AnalyticsDay: AnalyticsMetricPoint] = [:]
        for point in first + again {
            let old = byDay[point.day]?.value ?? 0
            byDay[point.day] = AnalyticsMetricPoint(day: point.day, value: old + point.value, processingDay: point.processingDay)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}

private struct AnalyticsMetricRow: View {
    let title: String
    let value: AnalyticsMetricValue
    let unit: AnalyticsMetricUnit

    var body: some View {
        LabeledContent(title) {
            Text(formattedValue)
                .foregroundStyle(value.numericValue == nil ? .secondary : .primary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var formattedValue: String {
        switch value {
        case .value(let value):
            switch unit {
            case .count: value.formatted(.number.precision(.fractionLength(0...1)))
            case .usd: value.formatted(.currency(code: "USD"))
            }
        case .noData: "No Data"
        case .notAvailable: "Not Available"
        case .insufficientData: "Insufficient Data"
        }
    }
}

private struct AnalyticsMethodologyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Not Real Time") {
                    Text("Apple's reports generally become complete two to five days after an event, depending on the report. ReviewBar always shows the actual data-through date.")
                }
                Section("Privacy") {
                    Text("Apple may add statistical noise or omit low-volume usage rows. ReviewBar distinguishes an explicit zero from no data and insufficient data.")
                }
                Section("Conversion") {
                    Text("ReviewBar doesn't manufacture a multi-day conversion rate. Apple's unique-impression and paying-user values aren't safely additive across days or dimensions.")
                }
                Section("Long Ranges") {
                    Text("Ongoing report instances remain available from Apple for a limited period. ReviewBar retains downloaded daily aggregates on this device, so 90-day and one-year coverage improves over time.")
                }
            }
            .navigationTitle("About Analytics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
