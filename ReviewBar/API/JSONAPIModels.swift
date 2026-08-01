import Foundation

struct JSONAPIPage<Resource: Decodable & Sendable, Included: Decodable & Sendable>: Decodable, Sendable {
    let data: [Resource]
    let included: [Included]?
    let links: JSONAPILinks
}

struct JSONAPILinks: Decodable, Sendable {
    let next: URL?
}

struct ResourceIdentifier: Decodable, Sendable {
    let type: String
    let id: String
}

struct ToOneRelationship: Decodable, Sendable {
    let data: ResourceIdentifier?
}

struct ToManyRelationship: Decodable, Sendable {
    let data: [ResourceIdentifier]
}

struct EmptyIncluded: Decodable, Sendable {}

struct AppAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let name: String
        let bundleId: String
        let sku: String?
        let primaryLocale: String?
    }

    struct Relationships: Decodable, Sendable {
        let appStoreIcon: ToOneRelationship?
    }

    let type: String
    let id: String
    let attributes: Attributes
    let relationships: Relationships?
}

struct ImageAssetAPIValue: Decodable, Sendable {
    let templateUrl: URL?
    let width: Int?
    let height: Int?
}

struct BuildIconAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let iconAsset: ImageAssetAPIValue?
        let iconType: String?
        let masked: Bool?
        let name: String?
    }

    let type: String
    let id: String
    let attributes: Attributes?

    func iconAsset(source: AppIconAsset.Source) -> AppIconAsset? {
        guard let image = attributes?.iconAsset, let templateURL = image.templateUrl else { return nil }
        return AppIconAsset(
            templateURL: templateURL,
            width: image.width,
            height: image.height,
            source: source
        )
    }
}

struct VersionAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let platform: String
        let versionString: String
        let appVersionState: String
        let releaseType: String?
        let earliestReleaseDate: Date?
        let createdDate: Date?
    }

    struct Relationships: Decodable, Sendable {
        let build: ToOneRelationship?
    }

    let type: String
    let id: String
    let attributes: Attributes
    let relationships: Relationships?
}

struct ReviewSubmissionAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let platform: String?
        let submittedDate: Date?
        let state: String
    }

    struct Relationships: Decodable, Sendable {
        let appStoreVersionForReview: ToOneRelationship?
    }

    let type: String
    let id: String
    let attributes: Attributes
    let relationships: Relationships?
}

struct CustomerReviewAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let rating: Int
        let title: String
        let body: String
        let reviewerNickname: String
        let createdDate: Date
        let territory: String?
    }

    struct Relationships: Decodable, Sendable {
        let response: ToOneRelationship?
    }

    let type: String
    let id: String
    let attributes: Attributes
    let relationships: Relationships?
}

struct CustomerReviewResponseAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let responseBody: String?
        let lastModifiedDate: Date?
        let state: String?
    }

    let type: String
    let id: String
    let attributes: Attributes
}

struct BuildAPIResource: Decodable, Sendable {
    struct Attributes: Decodable, Sendable {
        let version: String
        let uploadedDate: Date?
        let expirationDate: Date?
        let expired: Bool?
        let processingState: String
        let minOsVersion: String?
        let buildAudienceType: String?
    }

    struct Relationships: Decodable, Sendable {
        let preReleaseVersion: ToOneRelationship?
        let buildBetaDetail: ToOneRelationship?
        let betaAppReviewSubmission: ToOneRelationship?
        let appStoreVersion: ToOneRelationship?
        let icons: ToManyRelationship?
    }

    let type: String
    let id: String
    let attributes: Attributes
    let relationships: Relationships?
}

enum BuildIncludedAPIResource: Decodable, Sendable {
    struct PreReleaseVersion: Sendable {
        let id: String
        let version: String?
        let platform: String?
    }

    struct BetaDetail: Sendable {
        let id: String
        let internalBuildState: String?
        let externalBuildState: String?
    }

    struct BetaSubmission: Sendable {
        let id: String
        let betaReviewState: String?
        let submittedDate: Date?
    }

    struct AppStoreVersionReference: Sendable {
        let id: String
        let versionString: String?
    }

    struct BuildIcon: Sendable {
        let resource: BuildIconAPIResource
    }

    case preReleaseVersion(PreReleaseVersion)
    case betaDetail(BetaDetail)
    case betaSubmission(BetaSubmission)
    case appStoreVersion(AppStoreVersionReference)
    case buildIcon(BuildIcon)
    case unsupported(type: String, id: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, attributes
    }

    private struct PreReleaseAttributes: Decodable {
        let version: String?
        let platform: String?
    }

    private struct BetaDetailAttributes: Decodable {
        let internalBuildState: String?
        let externalBuildState: String?
    }

    private struct BetaSubmissionAttributes: Decodable {
        let betaReviewState: String?
        let submittedDate: Date?
    }

    private struct AppStoreVersionAttributes: Decodable {
        let versionString: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        switch type {
        case "preReleaseVersions":
            let attributes = try container.decode(PreReleaseAttributes.self, forKey: .attributes)
            self = .preReleaseVersion(PreReleaseVersion(id: id, version: attributes.version, platform: attributes.platform))
        case "buildBetaDetails":
            let attributes = try container.decode(BetaDetailAttributes.self, forKey: .attributes)
            self = .betaDetail(BetaDetail(
                id: id,
                internalBuildState: attributes.internalBuildState,
                externalBuildState: attributes.externalBuildState
            ))
        case "betaAppReviewSubmissions":
            let attributes = try container.decode(BetaSubmissionAttributes.self, forKey: .attributes)
            self = .betaSubmission(BetaSubmission(
                id: id,
                betaReviewState: attributes.betaReviewState,
                submittedDate: attributes.submittedDate
            ))
        case "appStoreVersions":
            let attributes = try container.decode(AppStoreVersionAttributes.self, forKey: .attributes)
            self = .appStoreVersion(AppStoreVersionReference(id: id, versionString: attributes.versionString))
        case "buildIcons":
            let resource = try BuildIconAPIResource(from: decoder)
            self = .buildIcon(BuildIcon(resource: resource))
        default:
            self = .unsupported(type: type, id: id)
        }
    }
}

enum AppleAPIDecoder {
    static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC 3339 date")
        }
        return decoder
    }
}
