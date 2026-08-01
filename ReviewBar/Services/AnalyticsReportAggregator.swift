import Foundation

enum AnalyticsReportAggregator {
    static func aggregate(
        reportName: String,
        processingDay: AnalyticsDay,
        documents: [TSVDocument]
    ) throws -> [AnalyticsMetricSeries] {
        try Task.checkCancellation()
        let allHeaders = Set(documents.flatMap(\.headers))
        let rows = documents.flatMap(\.rows)
        let name = normalized(reportName)
        if allHeaders.isEmpty {
            return emptySeries(reportName: reportName, normalizedName: name, processingDay: processingDay)
        }
        for document in documents where !document.headers.isEmpty {
            try validateHeaders(Set(document.headers), reportName: reportName, normalizedName: name)
        }
        if name.contains("app store downloads") {
            return try downloads(reportName: reportName, processingDay: processingDay, headers: allHeaders, rows: rows)
        }
        if name.contains("discovery and engagement") {
            return try engagement(reportName: reportName, processingDay: processingDay, headers: allHeaders, rows: rows)
        }
        if name.contains("app store purchases") {
            return try purchases(reportName: reportName, processingDay: processingDay, headers: allHeaders, rows: rows)
        }
        if name.contains("installations and deletions") {
            return try installations(reportName: reportName, processingDay: processingDay, headers: allHeaders, rows: rows)
        }
        if name.contains("app sessions") {
            return try numericReport(
                reportName: reportName,
                processingDay: processingDay,
                headers: allHeaders,
                rows: rows,
                column: "sessions",
                metric: .sessions,
                privacyThresholded: true
            )
        }
        if name.contains("app crashes") {
            return try numericReport(
                reportName: reportName,
                processingDay: processingDay,
                headers: allHeaders,
                rows: rows,
                column: "crashes",
                metric: .crashes,
                privacyThresholded: true
            )
        }
        return []
    }

    static func isSupportedReport(_ name: String) -> Bool {
        let name = normalized(name)
        return [
            "app store downloads", "discovery and engagement", "app store purchases",
            "installations and deletions", "app sessions", "app crashes"
        ].contains(where: name.contains)
        && !name.contains("detailed")
    }

    private static func downloads(
        reportName: String,
        processingDay: AnalyticsDay,
        headers: Set<String>,
        rows: [[String: String]]
    ) throws -> [AnalyticsMetricSeries] {
        try require(["date", "download type", "counts"], in: headers, reportName: reportName)
        let parsed = try rows.map { row in
            try Task.checkCancellation()
            return (row, try requiredDay(row, reportName: reportName), try requiredNumber(row["counts"], reportName: reportName))
        }
        let reportedDays = Set(parsed.map { $0.1 })
        var first = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        var again = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        for (row, day, value) in parsed {
            try Task.checkCancellation()
            switch normalized(row["download type"] ?? "") {
            case "first-time download", "first time download": first[day, default: 0] += value
            case "redownload": again[day, default: 0] += value
            default: break
            }
        }
        return [
            series(.firstTimeDownloads, values: first, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty),
            series(.redownloads, values: again, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty)
        ]
    }

    private static func emptySeries(
        reportName: String,
        normalizedName: String,
        processingDay: AnalyticsDay
    ) -> [AnalyticsMetricSeries] {
        let metrics: [AnalyticsMetricID]
        let thresholded: Bool
        if normalizedName.contains("app store downloads") {
            metrics = [.firstTimeDownloads, .redownloads]; thresholded = false
        } else if normalizedName.contains("discovery and engagement") {
            metrics = [.impressions, .productPageViews]; thresholded = false
        } else if normalizedName.contains("app store purchases") {
            metrics = [.inAppPurchases, .proceedsUSD]; thresholded = false
        } else if normalizedName.contains("installations and deletions") {
            metrics = [.installations, .deletions]; thresholded = true
        } else if normalizedName.contains("app sessions") {
            metrics = [.sessions]; thresholded = true
        } else if normalizedName.contains("app crashes") {
            metrics = [.crashes]; thresholded = true
        } else {
            return []
        }
        return metrics.map {
            series(
                $0,
                values: [:],
                processingDay: processingDay,
                reportName: reportName,
                rowsExist: false,
                privacyThresholded: thresholded
            )
        }
    }

    private static func engagement(
        reportName: String,
        processingDay: AnalyticsDay,
        headers: Set<String>,
        rows: [[String: String]]
    ) throws -> [AnalyticsMetricSeries] {
        try require(["date", "event", "counts"], in: headers, reportName: reportName)
        let parsed = try rows.map { row in
            try Task.checkCancellation()
            return (row, try requiredDay(row, reportName: reportName), try requiredNumber(row["counts"], reportName: reportName))
        }
        let reportedDays = Set(parsed.map { $0.1 })
        var impressions = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        var pageViews = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        for (row, day, value) in parsed {
            try Task.checkCancellation()
            let event = normalized(row["event"] ?? "")
            let pageType = normalized(row["page type"] ?? "")
            if event == "impression" { impressions[day, default: 0] += value }
            if event == "page view", pageType == "product page" { pageViews[day, default: 0] += value }
        }
        return [
            series(.impressions, values: impressions, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty),
            series(.productPageViews, values: pageViews, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty)
        ]
    }

    private static func purchases(
        reportName: String,
        processingDay: AnalyticsDay,
        headers: Set<String>,
        rows: [[String: String]]
    ) throws -> [AnalyticsMetricSeries] {
        try require(["date"], in: headers, reportName: reportName)
        guard headers.contains("purchases") || headers.contains("proceeds in usd") else {
            throw schemaError(reportName)
        }
        let parsed = try rows.map { row in
            try Task.checkCancellation()
            return (row, try requiredDay(row, reportName: reportName))
        }
        let reportedDays = Set(parsed.map { $0.1 })
        var purchases = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        var proceeds = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        for (row, day) in parsed {
            try Task.checkCancellation()
            let type = normalized(row["purchase type"] ?? row["content type"] ?? "")
            if type.contains("in-app purchase") || type.contains("in app purchase") {
                if let raw = row["purchases"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    purchases[day, default: 0] += try requiredNumber(raw, reportName: reportName)
                }
                if let raw = row["proceeds in usd"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    proceeds[day, default: 0] += try requiredNumber(raw, reportName: reportName)
                }
            }
        }
        return [
            series(.inAppPurchases, values: purchases, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty),
            series(.proceedsUSD, values: proceeds, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty)
        ]
    }

    private static func installations(
        reportName: String,
        processingDay: AnalyticsDay,
        headers: Set<String>,
        rows: [[String: String]]
    ) throws -> [AnalyticsMetricSeries] {
        try require(["date", "event", "counts"], in: headers, reportName: reportName)
        let parsed = try rows.compactMap { row -> ([String: String], AnalyticsDay, Double)? in
            try Task.checkCancellation()
            let parsedDay = try requiredDay(row, reportName: reportName)
            guard let value = try privacyNumber(row["counts"], reportName: reportName) else { return nil }
            return (row, parsedDay, value)
        }
        let reportedDays = Set(parsed.map { $0.1 })
        var installs = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        var deletes = Dictionary(uniqueKeysWithValues: reportedDays.map { ($0, 0.0) })
        for (row, day, value) in parsed {
            try Task.checkCancellation()
            let event = normalized(row["event"] ?? "")
            if event.hasPrefix("install") { installs[day, default: 0] += value }
            if event.hasPrefix("delet") { deletes[day, default: 0] += value }
        }
        return [
            series(.installations, values: installs, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty, privacyThresholded: true),
            series(.deletions, values: deletes, processingDay: processingDay, reportName: reportName, rowsExist: !rows.isEmpty, privacyThresholded: true)
        ]
    }

    private static func numericReport(
        reportName: String,
        processingDay: AnalyticsDay,
        headers: Set<String>,
        rows: [[String: String]],
        column: String,
        metric: AnalyticsMetricID,
        privacyThresholded: Bool
    ) throws -> [AnalyticsMetricSeries] {
        try require(["date", column], in: headers, reportName: reportName)
        var values: [AnalyticsDay: Double] = [:]
        for row in rows {
            try Task.checkCancellation()
            let day = try requiredDay(row, reportName: reportName)
            if let value = try privacyNumber(row[column], reportName: reportName) {
                values[day, default: 0] += value
            }
        }
        return [series(
            metric,
            values: values,
            processingDay: processingDay,
            reportName: reportName,
            rowsExist: !rows.isEmpty,
            privacyThresholded: privacyThresholded
        )]
    }

    private static func series(
        _ metric: AnalyticsMetricID,
        values: [AnalyticsDay: Double],
        processingDay: AnalyticsDay,
        reportName: String,
        rowsExist: Bool,
        privacyThresholded: Bool = false
    ) -> AnalyticsMetricSeries {
        let points = values.map { AnalyticsMetricPoint(day: $0.key, value: $0.value, processingDay: processingDay) }
            .sorted { $0.day < $1.day }
        let availability: AnalyticsSeriesAvailability = if !points.isEmpty {
            .available
        } else if privacyThresholded {
            .insufficientData
        } else {
            .noData
        }
        return AnalyticsMetricSeries(
            metric: metric,
            points: points,
            availability: availability,
            sourceReport: reportName,
            privacyThresholded: privacyThresholded
        )
    }

    private static func require(_ required: [String], in headers: Set<String>, reportName: String) throws {
        guard required.allSatisfy(headers.contains) else { throw schemaError(reportName) }
    }

    private static func validateHeaders(
        _ headers: Set<String>,
        reportName: String,
        normalizedName: String
    ) throws {
        if normalizedName.contains("app store downloads") {
            try require(["date", "download type", "counts"], in: headers, reportName: reportName)
        } else if normalizedName.contains("discovery and engagement") {
            try require(["date", "event", "counts"], in: headers, reportName: reportName)
        } else if normalizedName.contains("app store purchases") {
            try require(["date"], in: headers, reportName: reportName)
            guard headers.contains("purchases") || headers.contains("proceeds in usd") else { throw schemaError(reportName) }
        } else if normalizedName.contains("installations and deletions") {
            try require(["date", "event", "counts"], in: headers, reportName: reportName)
        } else if normalizedName.contains("app sessions") {
            try require(["date", "sessions"], in: headers, reportName: reportName)
        } else if normalizedName.contains("app crashes") {
            try require(["date", "crashes"], in: headers, reportName: reportName)
        }
    }

    private static func schemaError(_ reportName: String) -> AppError {
        AppError(kind: .malformedResponse, message: "Apple changed the \(reportName) report schema. Other Analytics data remains available.")
    }

    private static func day(_ row: [String: String]) -> AnalyticsDay? {
        row["date"].flatMap(AnalyticsDay.init(iso8601:))
    }

    private static func requiredDay(_ row: [String: String], reportName: String) throws -> AnalyticsDay {
        guard let day = day(row) else { throw schemaError(reportName) }
        return day
    }

    private static func requiredNumber(_ value: String?, reportName: String) throws -> Double {
        guard let number = number(value) else { throw schemaError(reportName) }
        return number
    }

    private static func privacyNumber(_ value: String?, reportName: String) throws -> Double? {
        guard let value else { throw schemaError(reportName) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["—", "n/a", "null", "insufficient data"].contains(trimmed.lowercased()) { return nil }
        guard let number = Double(trimmed) else { throw schemaError(reportName) }
        return number
    }

    private static func number(_ value: String?) -> Double? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || ["—", "n/a", "null", "insufficient data"].contains(normalized.lowercased()) { return nil }
        return Double(normalized)
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
