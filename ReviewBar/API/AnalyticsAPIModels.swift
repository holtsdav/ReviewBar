import Foundation

struct JSONAPISingle<Resource: Decodable & Sendable>: Decodable, Sendable {
    let data: Resource
    let links: JSONAPILinks?
}

struct AnalyticsReportRequestAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let accessType: String
        let stoppedDueToInactivity: Bool?
    }

    let type: String
    let id: String
    let attributes: Attributes
}

struct AnalyticsReportAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let name: String
        let category: String
    }

    let type: String
    let id: String
    let attributes: Attributes
}

struct AnalyticsReportInstanceAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let granularity: String
        let processingDate: String
    }

    let type: String
    let id: String
    let attributes: Attributes
}

struct AnalyticsReportSegmentAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let checksum: String?
        let sizeInBytes: Int?
        let url: URL?
    }

    let type: String
    let id: String
    let attributes: Attributes?
}

enum AnalyticsFetchResult: Sendable {
    case dataset(AnalyticsDataset)
    case notEnabled
    case generating
    case stoppedDueToInactivity
}
