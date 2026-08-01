import CryptoKit
import Foundation
import Testing
@testable import ReviewBar

struct AnalyticsTests {
    private let processingDay = AnalyticsDay(iso8601: "2026-08-01")!

    @Test("gzip Analytics segments decompress to their original TSV")
    func gzipDecompression() throws {
        let encoded = "H4sIAAAAAAAAA3NJLEnldMkvz8vJT0xRCKksSOV0zi/NKynmdCstKS1KVXDOzynNzeMyMjAy0zUw1zU24HTLLCou0Q3JzE1VgGnkNODMTi0oQagy5AxKTYFJGnPmpZZzAQCR90FuagAAAA=="
        let compressed = try #require(Data(base64Encoded: encoded))
        let decompressed = try GzipDecoder.decompress(compressed)
        let text = try #require(String(data: decompressed, encoding: .utf8))
        #expect(text.contains("First-Time Download\t0"))
        #expect(text.contains("Future Column"))
    }

    @Test("gzip expansion stops at the configured memory safety bound")
    func gzipExpansionBound() throws {
        let encoded = "H4sIAAAAAAAAA3NJLEnldMkvz8vJT0xRCKksSOV0zi/NKynmdCstKS1KVXDOzynNzeMyMjAy0zUw1zU24HTLLCou0Q3JzE1VgGnkNODMTi0oQagy5AxKTYFJGnPmpZZzAQCR90FuagAAAA=="
        let compressed = try #require(Data(base64Encoded: encoded))
        #expect(throws: AppError.self) {
            try GzipDecoder.decompress(compressed, maximumOutputBytes: 32)
        }
    }

    @Test("TSV parser accepts BOM, CRLF, quoted tabs, trailing fields, and unknown columns")
    func tsvParsing() throws {
        let input = "\u{FEFF}Date\tCounts\tFuture Column\tNote\r\n2026-07-31\t4\tnew\t\"contains\ta tab\"\r\n"
        let document = try TSVDocument.parse(Data(input.utf8))
        #expect(document.headers == ["date", "counts", "future column", "note"])
        #expect(document.rows[0]["note"] == "contains\ta tab")
        #expect(document.rows[0]["future column"] == "new")
    }

    @Test("Duplicate normalized TSV headers are rejected")
    func duplicateHeaders() {
        #expect(throws: AppError.self) {
            try TSVDocument.parse(Data("Date\t date \n2026-07-31\t2026-07-31\n".utf8))
        }
    }

    @Test("Impossible Gregorian report dates are rejected")
    func impossibleDate() {
        #expect(AnalyticsDay(iso8601: "2026-02-31") == nil)
        #expect(AnalyticsDay(iso8601: "2024-02-29") != nil)
    }

    @Test("Every Analytics segment must contain the required schema")
    func perSegmentSchemaValidation() throws {
        let valid = try TSVDocument.parse(Data("Date\tDownload Type\tCounts\n2026-07-31\tFirst-Time Download\t1\n".utf8))
        let malformed = try TSVDocument.parse(Data("Date\tDownload Type\n2026-07-31\tRedownload\n".utf8))
        #expect(throws: AppError.self) {
            try AnalyticsReportAggregator.aggregate(
                reportName: "App Store Downloads Standard",
                processingDay: processingDay,
                documents: [valid, malformed]
            )
        }
    }

    @Test("Malformed required counts cannot be manufactured into zeros")
    func malformedCount() throws {
        let malformed = try TSVDocument.parse(Data("Date\tDownload Type\tCounts\n2026-07-31\tRedownload\tbogus\n".utf8))
        #expect(throws: AppError.self) {
            try AnalyticsReportAggregator.aggregate(
                reportName: "App Store Downloads Standard",
                processingDay: processingDay,
                documents: [malformed]
            )
        }
    }

    @Test("Multi-segment download reports aggregate without dropping segments")
    func multiSegmentAggregation() throws {
        let first = try TSVDocument.parse(Data("Date\tDownload Type\tCounts\n2026-07-31\tFirst-Time Download\t2\n".utf8))
        let second = try TSVDocument.parse(Data("Date\tDownload Type\tCounts\n2026-07-31\tFirst-Time Download\t3\n2026-07-31\tRedownload\t1\n".utf8))
        let series = try AnalyticsReportAggregator.aggregate(
            reportName: "App Store Downloads Standard",
            processingDay: processingDay,
            documents: [first, second]
        )
        #expect(series.first { $0.metric == .firstTimeDownloads }?.points.first?.value == 5)
        #expect(series.first { $0.metric == .redownloads }?.points.first?.value == 1)
    }

    @Test("An empty report distinguishes no data from privacy-thresholded insufficient data")
    func emptyReports() throws {
        let empty = TSVDocument(headers: [], rows: [])
        let downloads = try AnalyticsReportAggregator.aggregate(
            reportName: "App Store Downloads Standard",
            processingDay: processingDay,
            documents: [empty]
        )
        let sessions = try AnalyticsReportAggregator.aggregate(
            reportName: "App Sessions Standard",
            processingDay: processingDay,
            documents: [empty]
        )
        #expect(downloads.allSatisfy { $0.availability == .noData })
        #expect(sessions.allSatisfy { $0.availability == .insufficientData })
    }

    @Test("A reported zero is a value, not no data")
    func zeroMetric() throws {
        let document = try TSVDocument.parse(Data("Date\tDownload Type\tCounts\n2026-07-31\tFirst-Time Download\t0\n".utf8))
        let series = try AnalyticsReportAggregator.aggregate(
            reportName: "App Store Downloads Standard",
            processingDay: processingDay,
            documents: [document]
        )
        let dataset = dataset(series: series)
        #expect(dataset.summary(range: .sevenDays).values[.firstTimeDownloads] == .value(0))
        #expect(dataset.summary(range: .sevenDays).values[.sessions] == .notAvailable)
    }

    @Test("A valid correction with no matching event replaces an older value with zero")
    func omittedEventCorrection() throws {
        let olderDocument = try TSVDocument.parse(Data("Date\tEvent\tPage Type\tCounts\n2026-07-31\tImpression\tProduct Page\t9\n".utf8))
        let newerDocument = try TSVDocument.parse(Data("Date\tEvent\tPage Type\tCounts\n2026-07-31\tPage View\tProduct Page\t2\n".utf8))
        let older = try AnalyticsReportAggregator.aggregate(
            reportName: "App Store Discovery and Engagement Standard",
            processingDay: try #require(AnalyticsDay(iso8601: "2026-08-01")),
            documents: [olderDocument]
        )
        let newer = try AnalyticsReportAggregator.aggregate(
            reportName: "App Store Discovery and Engagement Standard",
            processingDay: try #require(AnalyticsDay(iso8601: "2026-08-02")),
            documents: [newerDocument]
        )
        var value = dataset(series: older)
        value.merge(dataset(series: newer))
        #expect(value.series.first { $0.metric == .impressions }?.points.first?.value == 0)
    }

    @Test("Newer processing dates replace corrected values instead of summing them")
    func processingCorrections() throws {
        let day = try #require(AnalyticsDay(iso8601: "2026-07-31"))
        let older = AnalyticsMetricSeries(
            metric: .impressions,
            points: [AnalyticsMetricPoint(day: day, value: 100, processingDay: try #require(AnalyticsDay(iso8601: "2026-08-01")))],
            availability: .available,
            sourceReport: "Discovery and Engagement Standard"
        )
        let corrected = AnalyticsMetricSeries(
            metric: .impressions,
            points: [AnalyticsMetricPoint(day: day, value: 80, processingDay: try #require(AnalyticsDay(iso8601: "2026-08-02")))],
            availability: .available,
            sourceReport: "Discovery and Engagement Standard"
        )
        var saved = dataset(series: [older])
        saved.merge(dataset(series: [corrected]))
        #expect(saved.series[0].points == corrected.points)
    }

    @Test("An empty new import keeps older long-range points and adopts ongoing request metadata")
    func mergeRetainsHistoryAndMetadata() throws {
        let day = try #require(AnalyticsDay(iso8601: "2026-01-01"))
        var saved = AnalyticsDataset(
            appID: "app",
            requestID: "snapshot",
            accessType: "ONE_TIME_SNAPSHOT",
            series: [AnalyticsMetricSeries(
                metric: .sessions,
                points: [AnalyticsMetricPoint(day: day, value: 12, processingDay: processingDay)],
                availability: .available,
                sourceReport: "App Sessions Standard"
            )],
            fetchedAt: .distantPast,
            warnings: []
        )
        let incoming = AnalyticsDataset(
            appID: "app",
            requestID: "ongoing",
            accessType: "ONGOING",
            series: [AnalyticsMetricSeries(
                metric: .sessions,
                points: [],
                availability: .insufficientData,
                sourceReport: "App Sessions Standard",
                privacyThresholded: true
            )],
            fetchedAt: .now,
            warnings: []
        )

        saved.merge(incoming)
        #expect(saved.requestID == "ongoing")
        #expect(saved.accessType == "ONGOING")
        #expect(saved.series[0].availability == .available)
        #expect(saved.series[0].points.first?.value == 12)
        #expect(saved.series[0].privacyThresholded == true)
    }

    @Test("Range aggregation uses the report's data-through day and preserves calendar dates")
    func dateAggregation() throws {
        let baseDay = try #require(AnalyticsDay(iso8601: "2026-07-01"))
        let points = try (0..<10).map { offset -> AnalyticsMetricPoint in
            let date = try #require(Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: offset,
                to: baseDay.date
            ))
            return AnalyticsMetricPoint(
                day: AnalyticsDay(date: date),
                value: 1,
                processingDay: processingDay
            )
        }
        let series = AnalyticsMetricSeries(
            metric: .sessions,
            points: points,
            availability: .available,
            sourceReport: "App Sessions Standard"
        )
        let summary = dataset(series: [series]).summary(range: .sevenDays)
        #expect(summary.values[.sessions] == .value(7))
        #expect(summary.coverageStart?.iso8601 == "2026-07-04")
        #expect(summary.coverageEnd?.iso8601 == "2026-07-10")
    }

    @Test("No report request remains an explicit not-enabled state")
    func requestNotGenerated() async throws {
        let repository = AnalyticsRepository(
            provider: StubAnalyticsProvider(result: .notEnabled),
            cache: MemoryAnalyticsCache()
        )
        switch try await repository.refresh(appID: "app") {
        case .notEnabled: break
        default: Issue.record("Expected the not-enabled result")
        }
    }

    @Test("Analytics permission failures remain actionable")
    func permissionFailure() async {
        let repository = AnalyticsRepository(
            provider: StubAnalyticsProvider(error: AppError(
                kind: .insufficientPermission,
                message: "An Admin must create the initial Analytics Report request."
            )),
            cache: MemoryAnalyticsCache()
        )
        do {
            _ = try await repository.refresh(appID: "app")
            Issue.record("Expected permission failure")
        } catch let error as AppError {
            #expect(error.kind == .insufficientPermission)
            #expect(error.message.contains("Admin"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Analytics cache round-trips and reports its storage size")
    func analyticsCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalyticsCache(directoryURL: directory)
        let value = dataset(series: [])
        try await cache.save(value)
        #expect(try await cache.load(appID: value.appID) == value)
        #expect(await cache.sizeInBytes() > 0)
        try await cache.clear()
        #expect(try await cache.load(appID: value.appID) == nil)
    }

    @Test("A corrupt aggregate Analytics cache is removed and can be replaced")
    func corruptAnalyticsCacheRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "app.json")
        try Data("{truncated".utf8).write(to: file)
        let cache = AnalyticsCache(directoryURL: directory)

        #expect(try await cache.load(appID: "app") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let value = dataset(series: [])
        try await cache.save(value)
        #expect(try await cache.load(appID: "app") == value)
    }

    @Test("A corrupt Analytics instance cache is removed and can be replaced")
    func corruptInstanceCacheRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let instanceID = "instance-corrupt"
        let digest = SHA256.hash(data: Data(instanceID.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: "\(digest).json")
        try Data("not-json".utf8).write(to: file)
        let cache = AnalyticsInstanceCache(directoryURL: directory)

        #expect(try await cache.load(instanceID: instanceID, reportName: "App Sessions Standard", processingDay: processingDay) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let archive = AnalyticsInstanceArchive(reportName: "App Sessions Standard", processingDay: processingDay, series: [])
        try await cache.save(archive, instanceID: instanceID)
        #expect(try await cache.load(instanceID: instanceID, reportName: archive.reportName, processingDay: processingDay) == [])
    }

    @Test("Canceling an in-flight Analytics refresh cannot repopulate cleared storage")
    func cancelledRefreshDoesNotRepopulateCache() async throws {
        let cache = MemoryAnalyticsCache()
        let repository = AnalyticsRepository(
            provider: CancellationIgnoringAnalyticsProvider(dataset: dataset(series: [])),
            cache: cache
        )
        let refresh = Task { try await repository.refresh(appID: "app") }
        await Task.yield()
        try await repository.clear()
        _ = try? await refresh.value
        #expect(await cache.load(appID: "app") == nil)
    }

    private func dataset(series: [AnalyticsMetricSeries]) -> AnalyticsDataset {
        AnalyticsDataset(
            appID: "app",
            requestID: "request",
            accessType: "ONGOING",
            series: series,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            warnings: []
        )
    }
}

private actor StubAnalyticsProvider: AnalyticsDataProviding {
    let result: AnalyticsFetchResult?
    let error: AppError?

    init(result: AnalyticsFetchResult) {
        self.result = result
        error = nil
    }

    init(error: AppError) {
        result = nil
        self.error = error
    }

    func fetchAnalytics(appID: String) throws -> AnalyticsFetchResult {
        if let error { throw error }
        return result ?? .generating
    }

    func createOngoingRequest(appID: String) throws {
        if let error { throw error }
    }
}

private actor CancellationIgnoringAnalyticsProvider: AnalyticsDataProviding {
    let dataset: AnalyticsDataset

    init(dataset: AnalyticsDataset) {
        self.dataset = dataset
    }

    func fetchAnalytics(appID: String) async throws -> AnalyticsFetchResult {
        try? await Task.sleep(for: .milliseconds(80))
        return .dataset(dataset)
    }

    func createOngoingRequest(appID: String) {}
}
