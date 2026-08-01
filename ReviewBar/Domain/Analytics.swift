import Foundation

struct AnalyticsDay: Codable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init?(iso8601 value: String) {
        let pieces = value.prefix(10).split(separator: "-")
        guard pieces.count == 3,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard let date = Self.utcCalendar.date(from: components) else { return nil }
        let validated = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard validated.year == year, validated.month == month, validated.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date) {
        let components = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    var date: Date {
        Self.utcCalendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: 12
        )) ?? .distantPast
    }

    var iso8601: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

enum AnalyticsRange: Int, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365

    var id: Int { rawValue }
    var title: String { self == .oneYear ? "1Y" : "\(rawValue)D" }
}

enum AnalyticsMetricID: String, Codable, CaseIterable, Hashable, Sendable {
    case impressions
    case productPageViews
    case firstTimeDownloads
    case redownloads
    case inAppPurchases
    case proceedsUSD
    case installations
    case sessions
    case crashes
    case deletions

    var title: String {
        switch self {
        case .impressions: "Impressions"
        case .productPageViews: "Product Page Views"
        case .firstTimeDownloads: "First-Time Downloads"
        case .redownloads: "Redownloads"
        case .inAppPurchases: "In-App Purchases"
        case .proceedsUSD: "IAP Proceeds"
        case .installations: "Installations"
        case .sessions: "Sessions"
        case .crashes: "Crashes"
        case .deletions: "Deletions"
        }
    }

    var category: AnalyticsMetricCategory {
        switch self {
        case .impressions, .productPageViews: .acquisition
        case .firstTimeDownloads, .redownloads: .downloads
        case .inAppPurchases, .proceedsUSD: .business
        case .installations, .sessions, .crashes, .deletions: .usage
        }
    }

    var unit: AnalyticsMetricUnit { self == .proceedsUSD ? .usd : .count }
}

enum AnalyticsMetricCategory: String, CaseIterable, Sendable {
    case acquisition = "Acquisition"
    case downloads = "Downloads"
    case business = "Business"
    case usage = "Usage"
}

enum AnalyticsMetricUnit: Codable, Hashable, Sendable {
    case count
    case usd
}

enum AnalyticsSeriesAvailability: String, Codable, Hashable, Sendable {
    case available
    case noData
    case insufficientData
}

struct AnalyticsMetricPoint: Identifiable, Codable, Hashable, Sendable {
    let day: AnalyticsDay
    let value: Double
    let processingDay: AnalyticsDay

    var id: AnalyticsDay { day }
}

struct AnalyticsMetricSeries: Codable, Hashable, Sendable {
    let metric: AnalyticsMetricID
    var points: [AnalyticsMetricPoint]
    var availability: AnalyticsSeriesAvailability
    let sourceReport: String
    var privacyThresholded: Bool? = nil
}

struct AnalyticsDataset: Codable, Hashable, Sendable {
    let appID: String
    var requestID: String
    var accessType: String
    var series: [AnalyticsMetricSeries]
    var fetchedAt: Date
    var warnings: [String]

    var dataThrough: AnalyticsDay? {
        series.flatMap(\.points).map(\.day).max()
    }

    mutating func merge(_ incoming: AnalyticsDataset) {
        for newSeries in incoming.series {
            if let index = series.firstIndex(where: { $0.metric == newSeries.metric }) {
                var byDay = Dictionary(uniqueKeysWithValues: series[index].points.map { ($0.day, $0) })
                for point in newSeries.points {
                    if let old = byDay[point.day], old.processingDay > point.processingDay { continue }
                    byDay[point.day] = point
                }
                series[index].points = byDay.values.sorted { $0.day < $1.day }
                // A recent empty instance must not hide valid older points
                // retained for long ranges. Availability describes the merged
                // series, not only the newest import.
                series[index].availability = byDay.isEmpty ? newSeries.availability : .available
                series[index].privacyThresholded = (series[index].privacyThresholded == true)
                    || (newSeries.privacyThresholded == true)
            } else {
                series.append(newSeries)
            }
        }
        requestID = incoming.requestID
        accessType = incoming.accessType
        fetchedAt = incoming.fetchedAt
        warnings = incoming.warnings
    }

    func summary(range: AnalyticsRange) -> AnalyticsSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var values: [AnalyticsMetricID: AnalyticsMetricValue] = [:]
        var chart: [AnalyticsMetricID: [AnalyticsMetricPoint]] = [:]
        var dataThroughByMetric: [AnalyticsMetricID: AnalyticsDay] = [:]
        var daysReportedByMetric: [AnalyticsMetricID: Int] = [:]
        for metric in AnalyticsMetricID.allCases {
            guard let metricSeries = series.first(where: { $0.metric == metric }) else {
                values[metric] = .notAvailable
                continue
            }
            guard metricSeries.availability == .available else {
                values[metric] = metricSeries.availability == .insufficientData ? .insufficientData : .noData
                continue
            }
            let end = metricSeries.points.map(\.day).max()
            let startDate = end.flatMap {
                calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: $0.date)
            }
            let start = startDate.map(AnalyticsDay.init(date:))
            let selected = metricSeries.points.filter { point in
                guard let start, let end else { return false }
                return point.day >= start && point.day <= end
            }
            chart[metric] = selected
            if let end { dataThroughByMetric[metric] = end }
            daysReportedByMetric[metric] = selected.count
            if selected.isEmpty {
                values[metric] = metricSeries.privacyThresholded == true ? .insufficientData : .noData
            } else {
                values[metric] = .value(selected.reduce(0) { $0 + $1.value })
            }
        }
        let selectedDays = chart.values.flatMap { $0.map(\.day) }
        return AnalyticsSummary(
            range: range,
            values: values,
            chartPoints: chart,
            coverageStart: selectedDays.min(),
            coverageEnd: selectedDays.max(),
            dataThroughByMetric: dataThroughByMetric,
            daysReportedByMetric: daysReportedByMetric,
            fetchedAt: fetchedAt,
            warnings: warnings
        )
    }
}

enum AnalyticsMetricValue: Equatable, Sendable {
    case value(Double)
    case noData
    case notAvailable
    case insufficientData

    var numericValue: Double? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

struct AnalyticsSummary: Sendable {
    let range: AnalyticsRange
    let values: [AnalyticsMetricID: AnalyticsMetricValue]
    let chartPoints: [AnalyticsMetricID: [AnalyticsMetricPoint]]
    let coverageStart: AnalyticsDay?
    let coverageEnd: AnalyticsDay?
    let dataThroughByMetric: [AnalyticsMetricID: AnalyticsDay]
    let daysReportedByMetric: [AnalyticsMetricID: Int]
    let fetchedAt: Date
    let warnings: [String]

    var totalDownloads: AnalyticsMetricValue {
        let first: AnalyticsMetricValue = values[.firstTimeDownloads] ?? .notAvailable
        let again: AnalyticsMetricValue = values[.redownloads] ?? .notAvailable
        switch (first, again) {
        case (.value(let lhs), .value(let rhs)): return .value(lhs + rhs)
        case (.value(let value), .notAvailable), (.notAvailable, .value(let value)): return .value(value)
        case (.noData, .noData): return .noData
        case (.insufficientData, _), (_, .insufficientData): return .insufficientData
        default: return .notAvailable
        }
    }
}

enum AnalyticsLoadState: Equatable, Sendable {
    case idle
    case loading(cached: AnalyticsDataset?)
    case available(AnalyticsDataset)
    case notEnabled(cached: AnalyticsDataset?)
    case generating(cached: AnalyticsDataset?)
    case stoppedDueToInactivity(cached: AnalyticsDataset?)
    case permissionRequired(String, cached: AnalyticsDataset?)
    case failed(message: String, cached: AnalyticsDataset?)

    var cachedDataset: AnalyticsDataset? {
        switch self {
        case .loading(let cached), .notEnabled(let cached), .generating(let cached),
             .stoppedDueToInactivity(let cached), .permissionRequired(_, let cached),
             .failed(_, let cached): cached
        case .available(let dataset): dataset
        default: nil
        }
    }
}
