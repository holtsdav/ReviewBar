import Charts
import SwiftUI

struct AnalyticsView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    let isActive: Bool
    @State private var range: AnalyticsRange = .sevenDays
    @State private var showingMethodology = false

    var body: some View {
        Group {
            if !isActive {
                // Keep the tab's navigation shell alive without constructing
                // charts and metric summaries while it is off-screen.
                Color.clear.accessibilityHidden(true)
            } else if let dashboard = activeDashboard {
                List {
                    Section {
                        AppSelectionPicker(dashboards: model.dashboards, selection: $selectedAppID)
                        .accessibilityLabel("Analytics app")
                        .accessibilityValue(dashboard.app.name)
                    }
                    Section {
                        Picker("Time Range", selection: $range) {
                            ForEach(AnalyticsRange.allCases) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Analytics time range")
                        .accessibilityValue(range.title)
                    }
                    stateContent(model.analyticsState(for: dashboard.id), appID: dashboard.id)
                }
                .refreshable { await model.loadAnalytics(appID: dashboard.id, force: true) }
                .task(id: "\(dashboard.id)-\(isActive)") {
                    guard isActive else { return }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("About Analytics", systemImage: "info.circle") { showingMethodology = true }
            }
        }
        .sheet(isPresented: $showingMethodology) { AnalyticsMethodologyView() }
        .onChange(of: model.dashboards.map(\.id), initial: true) { _, ids in
            if selectedAppID == nil || !ids.contains(selectedAppID ?? "") {
                selectedAppID = ids.first
            }
        }
    }

    private var activeDashboard: AppDashboard? {
        if let selectedAppID,
           let dashboard = model.dashboards.first(where: { $0.id == selectedAppID }) {
            return dashboard
        }
        return dashboard ?? model.dashboards.first
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
        case .notEnabled(let cached):
            statusContent(
                title: "Analytics Not Enabled",
                message: "Apple hasn't generated Analytics reports for this app. An Admin API key is required to create the initial ongoing report request.",
                symbol: "chart.xyaxis.line",
                cached: cached,
                actionTitle: "Enable Analytics"
            ) { Task { await model.enableAnalytics(appID: appID) } }
        case .generating(let cached):
            statusContent(
                title: "Apple Is Preparing Reports",
                message: "Apple's first Analytics report normally takes 1–2 days to generate. Pull to refresh later; existing cached data remains available.",
                symbol: "clock",
                cached: cached
            )
        case .stoppedDueToInactivity(let cached):
            statusContent(
                title: "Report Generation Stopped",
                message: "Apple stopped this request after a period of inactivity. An Admin can create a new ongoing request.",
                symbol: "pause.circle",
                cached: cached,
                actionTitle: "Create New Request"
            ) { Task { await model.enableAnalytics(appID: appID) } }
        case .permissionRequired(let message, let cached):
            statusContent(
                title: "Analytics Permission Required",
                message: message,
                symbol: "lock",
                cached: cached
            )
        case .failed(let message, let cached):
            if let cached {
                Section { Label(message, systemImage: "exclamationmark.triangle") }
                analyticsContent(cached, refreshing: false)
            } else {
                Section {
                    AnalyticsStatusMessage(
                        title: "Analytics Unavailable",
                        message: message,
                        symbol: "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func statusContent(
        title: String,
        message: String,
        symbol: String,
        cached: AnalyticsDataset?,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        if let cached {
            Section {
                Label(title, systemImage: symbol).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                if let actionTitle { Button(actionTitle, action: action) }
            } footer: {
                Text("Showing the last Analytics data saved on this device.")
            }
            analyticsContent(cached, refreshing: false)
        } else {
            Section {
                AnalyticsStatusMessage(
                    title: title,
                    message: message,
                    symbol: symbol,
                    actionTitle: actionTitle,
                    action: action
                )
            }
        }
    }

    @ViewBuilder
    private func analyticsContent(_ dataset: AnalyticsDataset, refreshing: Bool) -> some View {
        let summary = dataset.summary(range: range)
        if dataset.accessType == "ONE_TIME_SNAPSHOT" {
            Section {
                Label("One-Time Snapshot", systemImage: "camera.metering.partial")
                    .font(.headline)
                Text("These reports are a fixed snapshot. Create an ongoing request to keep Analytics updating.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Start Ongoing Reports") {
                    Task { await model.enableAnalytics(appID: dataset.appID) }
                }
            }
        }
        Section {
            let reportedDates = Set(summary.dataThroughByMetric.values)
            if reportedDates.count == 1, let date = reportedDates.first {
                LabeledContent("Data through", value: date.date.formatted(date: .abbreviated, time: .omitted))
            } else if let latest = reportedDates.max() {
                LabeledContent("Latest reported date", value: latest.date.formatted(date: .abbreviated, time: .omitted))
                Text("Freshness varies by report; each metric group shows its own data-through date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if refreshing {
                Label("Updating from Apple…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Analytics is delayed and privacy-protected. The date above comes from report rows, not Apple's processing date.")
        }

        if dataset.series.isEmpty {
            Section {
                AnalyticsStatusMessage(
                    title: "No Analytics Data",
                    message: "Apple generated the report request, but it contains no supported metric rows yet. Pull to refresh after Apple publishes the next reports.",
                    symbol: "chart.xyaxis.line"
                )
            }
        }

        if let downloads = downloadChartPoints(summary), !downloads.isEmpty {
            Section("Downloads Trend") {
                Chart(downloads) { point in
                    BarMark(
                        x: .value("Date", point.day.date),
                        y: .value("Downloads", point.value)
                    )
                    .foregroundStyle(.tint)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: range == .sevenDays ? 4 : 3)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(minHeight: 170)
                .accessibilityLabel("Downloads over \(range.title)")
                .accessibilityValue(downloadChartAccessibilityValue(downloads))
            }
        }

        ForEach(AnalyticsMetricCategory.allCases, id: \.self) { category in
            let metrics = visibleMetrics(in: category, summary: summary)
            if !metrics.isEmpty || (category == .downloads && summary.totalDownloads != .notAvailable) {
                Section {
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
                } header: {
                    Text(category.rawValue)
                } footer: {
                    if let freshness = freshnessDescription(for: metrics, summary: summary) {
                        Text(freshness)
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

    private func freshnessDescription(
        for metrics: [AnalyticsMetricID],
        summary: AnalyticsSummary
    ) -> String? {
        let relevant = metrics + (metrics.first?.category == .downloads ? [.firstTimeDownloads, .redownloads] : [])
        let dates = Set(relevant.compactMap { summary.dataThroughByMetric[$0] })
        guard !dates.isEmpty else { return nil }
        if dates.count == 1, let date = dates.first {
            return "Data through \(date.date.formatted(date: .abbreviated, time: .omitted))."
        }
        return dates.sorted().map { $0.date.formatted(date: .abbreviated, time: .omitted) }
            .joined(separator: " – ")
            .appending(" data-through range; individual reports update at different times.")
    }

    private func downloadChartAccessibilityValue(_ points: [AnalyticsMetricPoint]) -> String {
        let total = points.reduce(0) { $0 + $1.value }
        guard let first = points.first?.day, let last = points.last?.day else {
            return "No reported downloads."
        }
        return "\(total.formatted(.number.precision(.fractionLength(0)))) total downloads from \(first.iso8601) through \(last.iso8601), across \(points.count) reported days."
    }
}

private struct AnalyticsStatusMessage: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
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
