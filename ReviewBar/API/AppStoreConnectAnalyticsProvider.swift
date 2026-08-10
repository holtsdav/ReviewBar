import Foundation

struct AppStoreConnectAnalyticsProvider: AnalyticsDataProviding, Sendable {
    private let transport: AppleAPITransport
    private let downloader: AnalyticsSegmentDownloader
    private let instanceCache: any AnalyticsInstanceCaching
    private let baseURL: URL

    init(credential: AppStoreConnectCredential) throws {
        guard let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1") else {
            throw AppError(kind: .other, message: "ReviewBar's Apple Analytics API address is invalid.")
        }
        transport = AppleAPITransport(signer: try JWTGenerator(credential: credential))
        downloader = AnalyticsSegmentDownloader()
        instanceCache = AnalyticsInstanceCache()
        self.baseURL = baseURL
    }

    init(
        transport: AppleAPITransport,
        downloader: AnalyticsSegmentDownloader,
        baseURL: URL,
        instanceCache: any AnalyticsInstanceCaching = MemoryAnalyticsInstanceCache()
    ) {
        self.transport = transport
        self.downloader = downloader
        self.baseURL = baseURL
        self.instanceCache = instanceCache
    }

    func fetchAnalytics(appID: String) async throws -> AnalyticsFetchResult {
        let requestsURL = try makeURL(path: "apps/\(appID)/analyticsReportRequests", query: [
            URLQueryItem(name: "fields[analyticsReportRequests]", value: "accessType,stoppedDueToInactivity"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let requests: [AnalyticsReportRequestAPIResource] = try await fetchAllPages(from: requestsURL)
        let ongoing = requests.first { $0.attributes.accessType == "ONGOING" && $0.attributes.stoppedDueToInactivity != true }
        let snapshot = requests.first { $0.attributes.accessType == "ONE_TIME_SNAPSHOT" }
        guard let request = ongoing ?? snapshot else {
            if requests.contains(where: { $0.attributes.accessType == "ONGOING" && $0.attributes.stoppedDueToInactivity == true }) {
                return .stoppedDueToInactivity
            }
            return .notEnabled
        }

        let reportsURL = try makeURL(path: "analyticsReportRequests/\(request.id)/reports", query: [
            URLQueryItem(name: "fields[analyticsReports]", value: "name,category"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let allReports: [AnalyticsReportAPIResource] = try await fetchAllPages(from: reportsURL)
        let reports = allReports.filter { AnalyticsReportAggregator.isSupportedReport($0.attributes.name) }
        guard !allReports.isEmpty else { return .generating }
        if reports.isEmpty {
            return .dataset(AnalyticsDataset(
                appID: appID,
                requestID: request.id,
                accessType: request.attributes.accessType,
                series: [],
                fetchedAt: .now,
                warnings: ["Apple returned Analytics report types this version of ReviewBar doesn't recognize yet."]
            ))
        }

        var series: [AnalyticsMetricSeries] = []
        var warnings: [String] = []
        // Import one report at a time. TSV rows are intentionally bounded but
        // still retained for report-specific aggregation, so parallel imports
        // would multiply peak memory without improving the quick-check UX.
        for report in reports {
            try Task.checkCancellation()
            do {
                merge(try await fetchReport(report), into: &series)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mapped = AppError.map(error)
                if mapped.kind == .malformedResponse {
                    warnings.append("\(report.attributes.name): \(mapped.message)")
                } else {
                    throw mapped
                }
            }
        }
        if series.isEmpty && warnings.isEmpty { return .generating }
        return .dataset(AnalyticsDataset(
            appID: appID,
            requestID: request.id,
            accessType: request.attributes.accessType,
            series: series,
            fetchedAt: .now,
            warnings: warnings
        ))
    }

    func createOngoingRequest(appID: String) async throws {
        let url = try makeURL(path: "analyticsReportRequests", query: [])
        let payload: [String: Any] = [
            "data": [
                "type": "analyticsReportRequests",
                "attributes": ["accessType": "ONGOING"],
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appID]]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        _ = try await transport.post(url, body: body)
    }

    func clearImportedData() async throws {
        try await instanceCache.clear()
    }

    func importedDataSizeInBytes() async -> Int64 {
        await instanceCache.sizeInBytes()
    }

    private func fetchReport(_ report: AnalyticsReportAPIResource) async throws -> [AnalyticsMetricSeries] {
        let instancesURL = try makeURL(path: "analyticsReports/\(report.id)/instances", query: [
            URLQueryItem(name: "filter[granularity]", value: "DAILY"),
            URLQueryItem(name: "fields[analyticsReportInstances]", value: "granularity,processingDate"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let instances: [AnalyticsReportInstanceAPIResource] = try await fetchAllPages(from: instancesURL)
        var imported: [AnalyticsMetricSeries] = []
        for instance in instances {
            try Task.checkCancellation()
            merge(try await fetchInstance(instance, reportName: report.attributes.name), into: &imported)
        }
        return imported
    }

    private func fetchInstance(
        _ instance: AnalyticsReportInstanceAPIResource,
        reportName: String
    ) async throws -> [AnalyticsMetricSeries] {
        guard instance.attributes.granularity == "DAILY",
              let processingDay = AnalyticsDay(iso8601: instance.attributes.processingDate) else {
            throw AppError(kind: .malformedResponse, message: "Apple returned an invalid Analytics processing date.")
        }
        if let cached = try await instanceCache.load(
            instanceID: instance.id,
            reportName: reportName,
            processingDay: processingDay
        ) {
            return cached
        }
        let segments = try await fetchSegments(instanceID: instance.id)
        var series: [AnalyticsMetricSeries] = []
        for segment in segments {
            try Task.checkCancellation()
            let compressed: Data
            do {
                compressed = try await downloader.download(segment)
            } catch AnalyticsSegmentDownloadError.expiredURL {
                let refreshed = try await fetchSegment(id: segment.id)
                compressed = try await downloader.download(refreshed)
            }
            let document = try TSVDocument.parse(GzipDecoder.decompress(compressed))
            let imported = try AnalyticsReportAggregator.aggregate(
                reportName: reportName,
                processingDay: processingDay,
                documents: [document]
            )
            combineSegments(imported, into: &series)
        }
        try await instanceCache.save(
            AnalyticsInstanceArchive(reportName: reportName, processingDay: processingDay, series: series),
            instanceID: instance.id
        )
        return series
    }

    private func combineSegments(
        _ incoming: [AnalyticsMetricSeries],
        into existing: inout [AnalyticsMetricSeries]
    ) {
        for segmentSeries in incoming {
            guard let index = existing.firstIndex(where: { $0.metric == segmentSeries.metric }) else {
                existing.append(segmentSeries)
                continue
            }
            var points = Dictionary(uniqueKeysWithValues: existing[index].points.map { ($0.day, $0) })
            for point in segmentSeries.points {
                let saved = points[point.day]
                points[point.day] = AnalyticsMetricPoint(
                    day: point.day,
                    value: (saved?.value ?? 0) + point.value,
                    processingDay: max(saved?.processingDay ?? point.processingDay, point.processingDay)
                )
            }
            existing[index].points = points.values.sorted { $0.day < $1.day }
            if segmentSeries.availability == .available { existing[index].availability = .available }
        }
    }

    private func fetchSegments(instanceID: String) async throws -> [AnalyticsReportSegmentAPIResource] {
        let url = try makeURL(path: "analyticsReportInstances/\(instanceID)/segments", query: [
            URLQueryItem(name: "fields[analyticsReportSegments]", value: "checksum,sizeInBytes,url"),
            URLQueryItem(name: "limit", value: "200")
        ])
        return try await fetchAllPages(from: url)
    }

    private func fetchSegment(id: String) async throws -> AnalyticsReportSegmentAPIResource {
        let url = try makeURL(path: "analyticsReportSegments/\(id)", query: [
            URLQueryItem(name: "fields[analyticsReportSegments]", value: "checksum,sizeInBytes,url")
        ])
        let response = try await transport.get(url)
        return try AppleAPIDecoder.make().decode(
            JSONAPISingle<AnalyticsReportSegmentAPIResource>.self,
            from: response.data
        ).data
    }

    private func fetchAllPages<Resource: Decodable & Sendable>(from initialURL: URL) async throws -> [Resource] {
        var nextURL: URL? = initialURL
        var resources: [Resource] = []
        var visited: Set<URL> = []
        var pageCount = 0
        while let url = nextURL {
            try Task.checkCancellation()
            guard visited.insert(url).inserted, pageCount < 100 else {
                throw AppError(kind: .malformedResponse, message: "Apple returned a repeating Analytics pagination chain.")
            }
            let response = try await transport.get(url)
            let page = try AppleAPIDecoder.make().decode(JSONAPIPage<Resource, EmptyIncluded>.self, from: response.data)
            resources.append(contentsOf: page.data)
            nextURL = page.links.next
            pageCount += 1
        }
        return resources
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        let url = path.split(separator: "/").reduce(baseURL) { $0.appending(path: String($1)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AppError(kind: .other, message: "ReviewBar couldn't create an Analytics request.")
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else {
            throw AppError(kind: .other, message: "ReviewBar couldn't encode an Analytics request.")
        }
        return result
    }

    private func merge(_ incoming: [AnalyticsMetricSeries], into existing: inout [AnalyticsMetricSeries]) {
        for newSeries in incoming {
            guard let index = existing.firstIndex(where: { $0.metric == newSeries.metric }) else {
                existing.append(newSeries)
                continue
            }
            var points = Dictionary(uniqueKeysWithValues: existing[index].points.map { ($0.day, $0) })
            for point in newSeries.points {
                if let saved = points[point.day], saved.processingDay > point.processingDay { continue }
                points[point.day] = point
            }
            existing[index].points = points.values.sorted { $0.day < $1.day }
            if newSeries.availability == .available { existing[index].availability = .available }
        }
    }
}
