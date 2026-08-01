import Foundation

struct AppStoreConnectAnalyticsProvider: AnalyticsDataProviding, Sendable {
    private let transport: AppleAPITransport
    private let downloader: AnalyticsSegmentDownloader
    private let baseURL: URL

    init(credential: AppStoreConnectCredential) throws {
        guard let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1") else {
            throw AppError(kind: .other, message: "ReviewBar's Apple Analytics API address is invalid.")
        }
        transport = AppleAPITransport(signer: try JWTGenerator(credential: credential))
        downloader = AnalyticsSegmentDownloader()
        self.baseURL = baseURL
    }

    init(transport: AppleAPITransport, downloader: AnalyticsSegmentDownloader, baseURL: URL) {
        self.transport = transport
        self.downloader = downloader
        self.baseURL = baseURL
    }

    func fetchAnalytics(appID: String) async throws -> AnalyticsFetchResult {
        let requestsURL = try makeURL(path: "apps/\(appID)/analyticsReportRequests", query: [
            URLQueryItem(name: "fields[analyticsReportRequests]", value: "accessType,stoppedDueToInactivity"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let requests: [AnalyticsReportRequestAPIResource] = try await fetchAllPages(from: requestsURL)
        let ongoing = requests.first { $0.attributes.accessType == "ONGOING" && $0.attributes.stoppedDueToInactivity != true }
        guard let request = ongoing else {
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

        var series: [AnalyticsMetricSeries] = []
        var warnings: [String] = []
        for batchStart in stride(from: 0, to: reports.count, by: 3) {
            try Task.checkCancellation()
            let batch = Array(reports[batchStart..<min(batchStart + 3, reports.count)])
            let results = await withTaskGroup(of: ReportImportResult.self) { group in
                for report in batch {
                    group.addTask {
                        do {
                            return .success(report.attributes.name, try await fetchReport(report))
                        } catch is CancellationError {
                            return .cancelled
                        } catch {
                            return .failure(report.attributes.name, AppError.map(error).message)
                        }
                    }
                }
                var values: [ReportImportResult] = []
                for await value in group { values.append(value) }
                return values
            }
            for result in results {
                switch result {
                case .success(_, let imported): merge(imported, into: &series)
                case .failure(let name, let message): warnings.append("\(name): \(message)")
                case .cancelled: throw CancellationError()
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

    private func fetchReport(_ report: AnalyticsReportAPIResource) async throws -> [AnalyticsMetricSeries] {
        let instancesURL = try makeURL(path: "analyticsReports/\(report.id)/instances", query: [
            URLQueryItem(name: "filter[granularity]", value: "DAILY"),
            URLQueryItem(name: "fields[analyticsReportInstances]", value: "granularity,processingDate"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let instances: [AnalyticsReportInstanceAPIResource] = try await fetchAllPages(from: instancesURL)
        var imported: [AnalyticsMetricSeries] = []
        for batchStart in stride(from: 0, to: instances.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(instances[batchStart..<min(batchStart + 4, instances.count)])
            let chunks = try await withThrowingTaskGroup(of: [AnalyticsMetricSeries].self) { group in
                for instance in batch {
                    group.addTask { try await fetchInstance(instance, reportName: report.attributes.name) }
                }
                var values: [[AnalyticsMetricSeries]] = []
                for try await value in group { values.append(value) }
                return values
            }
            for chunk in chunks { merge(chunk, into: &imported) }
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
        let segments = try await fetchSegments(instanceID: instance.id)
        var documents: [TSVDocument] = []
        documents.reserveCapacity(segments.count)
        for segment in segments {
            try Task.checkCancellation()
            let compressed: Data
            do {
                compressed = try await downloader.download(segment)
            } catch AnalyticsSegmentDownloadError.expiredURL {
                let refreshed = try await fetchSegment(id: segment.id)
                compressed = try await downloader.download(refreshed)
            }
            documents.append(try TSVDocument.parse(GzipDecoder.decompress(compressed)))
        }
        return try AnalyticsReportAggregator.aggregate(
            reportName: reportName,
            processingDay: processingDay,
            documents: documents
        )
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

private enum ReportImportResult: Sendable {
    case success(String, [AnalyticsMetricSeries])
    case failure(String, String)
    case cancelled
}
