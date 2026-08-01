import Foundation

struct AppStoreConnectDataProvider: DashboardDataProviding, Sendable {
    private let transport: AppleAPITransport
    private let baseURL: URL

    init(credential: AppStoreConnectCredential) throws {
        guard let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1") else {
            throw AppError(kind: .other, message: "ReviewBar’s Apple API address is invalid.")
        }
        let signer = try JWTGenerator(credential: credential)
        transport = AppleAPITransport(signer: signer)
        self.baseURL = baseURL
    }

    init(transport: AppleAPITransport, baseURL: URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    func fetchApps() async throws -> [DeveloperApp] {
        let url = try makeURL(path: "apps", query: [
            URLQueryItem(name: "fields[apps]", value: "name,bundleId,sku,primaryLocale,appStoreIcon"),
            URLQueryItem(name: "include", value: "appStoreIcon"),
            URLQueryItem(name: "fields[buildIcons]", value: "iconAsset,iconType,masked,name"),
            URLQueryItem(name: "sort", value: "name"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let pages: ([AppAPIResource], [BuildIconAPIResource]) = try await fetchAllPages(from: url)
        let iconsByID = Dictionary(
            pages.1.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        return pages.0.compactMap { resource -> DeveloperApp? in
            guard seen.insert(resource.id).inserted else { return nil }
            return DeveloperApp(
                id: resource.id,
                name: resource.attributes.name,
                bundleID: resource.attributes.bundleId,
                sku: resource.attributes.sku,
                primaryLocale: resource.attributes.primaryLocale,
                iconAsset: resource.relationships?.appStoreIcon?.data
                    .flatMap { iconsByID[$0.id] }?.iconAsset(source: .appStore)
            )
        }
    }

    func fetchDashboard(for app: DeveloperApp) async throws -> AppDashboard {
        async let releasesResult = capture { try await fetchReleases(appID: app.id) }
        async let reviewsResult = capture { try await fetchFirstReviewsPage(appID: app.id) }
        async let buildsResult = capture { try await fetchBuilds(appID: app.id) }

        let releases = try await releasesResult
        let reviews = try await reviewsResult
        let builds = try await buildsResult
        var issues: [DashboardSection: SectionIssue] = [:]
        if case .failure(let error) = releases { issues[.releases] = SectionIssue(error: error) }
        if case .failure(let error) = reviews { issues[.reviews] = SectionIssue(error: error) }
        if case .failure(let error) = builds { issues[.builds] = SectionIssue(error: error) }

        let reviewPage = (try? reviews.get()) ?? ReviewPage(reviews: [], nextPage: nil)
        let fetchedBuilds = (try? builds.get()) ?? FetchedBuilds(builds: [], fallbackIcon: nil)
        var resolvedApp = app
        if resolvedApp.iconAsset == nil { resolvedApp.iconAsset = fetchedBuilds.fallbackIcon }
        return AppDashboard(
            app: resolvedApp,
            releases: (try? releases.get()) ?? [],
            reviews: reviewPage.reviews,
            builds: fetchedBuilds.builds,
            nextReviewsPage: reviewPage.nextPage,
            fetchedAt: .now,
            sectionIssues: issues
        )
    }

    func fetchReviewsPage(at url: URL) async throws -> ReviewPage {
        let response = try await transport.get(url)
        let document = try AppleAPIDecoder.make().decode(
            JSONAPIPage<CustomerReviewAPIResource, CustomerReviewResponseAPIResource>.self,
            from: response.data
        )
        return mapReviews(document.data, responses: document.included ?? [], next: document.links.next)
    }

    private func fetchReleases(appID: String) async throws -> [AppRelease] {
        let versionsURL = try makeURL(path: "apps/\(appID)/appStoreVersions", query: [
            URLQueryItem(name: "fields[appStoreVersions]", value: "platform,versionString,appVersionState,releaseType,earliestReleaseDate,createdDate,build"),
            URLQueryItem(name: "limit", value: "200")
        ])
        let submissionsURL = try makeURL(path: "apps/\(appID)/reviewSubmissions", query: [
            URLQueryItem(name: "fields[reviewSubmissions]", value: "platform,submittedDate,state,appStoreVersionForReview"),
            URLQueryItem(name: "limit", value: "200")
        ])

        async let versions: ([VersionAPIResource], [EmptyIncluded]) = fetchAllPages(from: versionsURL)
        async let submissions: ([ReviewSubmissionAPIResource], [EmptyIncluded]) = fetchAllPages(from: submissionsURL)
        let (versionPages, submissionPages) = try await (versions, submissions)

        let submissionsByVersion = Dictionary(
            submissionPages.0.compactMap { submission -> (String, ReviewSubmissionAPIResource)? in
                guard let versionID = submission.relationships?.appStoreVersionForReview?.data?.id else { return nil }
                return (versionID, submission)
            },
            uniquingKeysWith: { first, second in
                let firstDate = first.attributes.submittedDate ?? .distantPast
                let secondDate = second.attributes.submittedDate ?? .distantPast
                return firstDate >= secondDate ? first : second
            }
        )

        var seen: Set<String> = []
        return versionPages.0.compactMap { resource in
            guard seen.insert(resource.id).inserted else { return nil }
            let submission = submissionsByVersion[resource.id]
            return AppRelease(
                id: resource.id,
                version: resource.attributes.versionString,
                platform: .init(apiValue: resource.attributes.platform),
                state: .init(apiValue: resource.attributes.appVersionState),
                createdDate: resource.attributes.createdDate,
                submittedDate: submission?.attributes.submittedDate,
                earliestReleaseDate: resource.attributes.earliestReleaseDate,
                releaseType: resource.attributes.releaseType,
                selectedBuildID: resource.relationships?.build?.data?.id,
                reviewSubmissionState: submission?.attributes.state
            )
        }
        .sorted { lhs, rhs in
            (lhs.createdDate ?? .distantPast) > (rhs.createdDate ?? .distantPast)
        }
    }

    private func fetchFirstReviewsPage(appID: String) async throws -> ReviewPage {
        let url = try makeURL(path: "apps/\(appID)/customerReviews", query: [
            URLQueryItem(name: "fields[customerReviews]", value: "rating,title,body,reviewerNickname,createdDate,territory,response"),
            URLQueryItem(name: "include", value: "response"),
            URLQueryItem(name: "fields[customerReviewResponses]", value: "responseBody,lastModifiedDate,state"),
            URLQueryItem(name: "sort", value: "-createdDate"),
            URLQueryItem(name: "limit", value: "200")
        ])
        return try await fetchReviewsPage(at: url)
    }

    private func fetchBuilds(appID: String) async throws -> FetchedBuilds {
        let url = try makeURL(path: "builds", query: [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "include", value: "preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,appStoreVersion,icons"),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate,expirationDate,expired,processingState,minOsVersion,buildAudienceType,preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,appStoreVersion,icons"),
            URLQueryItem(name: "fields[preReleaseVersions]", value: "version,platform"),
            URLQueryItem(name: "fields[buildBetaDetails]", value: "internalBuildState,externalBuildState"),
            URLQueryItem(name: "fields[betaAppReviewSubmissions]", value: "betaReviewState,submittedDate"),
            URLQueryItem(name: "fields[appStoreVersions]", value: "versionString"),
            URLQueryItem(name: "fields[buildIcons]", value: "iconAsset,iconType,masked,name"),
            URLQueryItem(name: "limit[icons]", value: "50"),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "200")
        ])
        // Apple can split platforms across pages. Follow the complete safe
        // pagination chain so an iOS-heavy app cannot hide its macOS/tvOS/
        // visionOS or older still-active TestFlight builds.
        let pages: ([BuildAPIResource], [BuildIncludedAPIResource]) = try await fetchAllPages(from: url)

        var preReleases: [String: BuildIncludedAPIResource.PreReleaseVersion] = [:]
        var betaDetails: [String: BuildIncludedAPIResource.BetaDetail] = [:]
        var betaSubmissions: [String: BuildIncludedAPIResource.BetaSubmission] = [:]
        var appVersions: [String: BuildIncludedAPIResource.AppStoreVersionReference] = [:]
        var icons: [String: BuildIconAPIResource] = [:]
        for included in pages.1 {
            switch included {
            case .preReleaseVersion(let value): preReleases[value.id] = value
            case .betaDetail(let value): betaDetails[value.id] = value
            case .betaSubmission(let value): betaSubmissions[value.id] = value
            case .appStoreVersion(let value): appVersions[value.id] = value
            case .buildIcon(let value): icons[value.resource.id] = value.resource
            case .unsupported: break
            }
        }

        var seen: Set<String> = []
        let mappedBuilds = pages.0.compactMap { resource -> BuildInfo? in
            guard seen.insert(resource.id).inserted else { return nil }
            let relationships = resource.relationships
            let preRelease = relationships?.preReleaseVersion?.data.flatMap { preReleases[$0.id] }
            let betaDetail = relationships?.buildBetaDetail?.data.flatMap { betaDetails[$0.id] }
            let betaSubmission = relationships?.betaAppReviewSubmission?.data.flatMap { betaSubmissions[$0.id] }
            let appVersion = relationships?.appStoreVersion?.data.flatMap { appVersions[$0.id] }
            return BuildInfo(
                id: resource.id,
                buildNumber: resource.attributes.version,
                version: preRelease?.version,
                platform: .init(apiValue: preRelease?.platform ?? ""),
                uploadedDate: resource.attributes.uploadedDate,
                expirationDate: resource.attributes.expirationDate,
                expired: resource.attributes.expired ?? false,
                processingState: .init(apiValue: resource.attributes.processingState),
                minimumOSVersion: resource.attributes.minOsVersion,
                audienceType: resource.attributes.buildAudienceType,
                internalBetaState: betaDetail?.internalBuildState,
                externalBetaState: betaDetail?.externalBuildState,
                betaReviewState: betaSubmission?.betaReviewState,
                selectedForAppStoreVersion: appVersion?.versionString
            )
        }
        let sortedBuilds = mappedBuilds.sorted { lhs, rhs in
            (lhs.uploadedDate ?? .distantPast) > (rhs.uploadedDate ?? .distantPast)
        }
        let resourcesByID = Dictionary(pages.0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fallbackIcon = sortedBuilds.lazy.compactMap { build -> AppIconAsset? in
            guard let resource = resourcesByID[build.id] else { return nil }
            return resource.relationships?.icons?.data.lazy
                .compactMap { icons[$0.id] }
                .first(where: { $0.attributes?.iconType == "APP_STORE" })?
                .iconAsset(source: .build)
        }.first
        return FetchedBuilds(builds: sortedBuilds, fallbackIcon: fallbackIcon)
    }

    private func mapReviews(
        _ resources: [CustomerReviewAPIResource],
        responses: [CustomerReviewResponseAPIResource],
        next: URL?
    ) -> ReviewPage {
        let responseStates = Dictionary(
            responses.map {
                ($0.id, DeveloperResponseState(apiValue: $0.attributes.state ?? "UNKNOWN"))
            },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        let reviews = resources.compactMap { resource -> CustomerReview? in
            guard seen.insert(resource.id).inserted else { return nil }
            let responseID = resource.relationships?.response?.data?.id
            return CustomerReview(
                id: resource.id,
                rating: resource.attributes.rating,
                title: resource.attributes.title,
                body: resource.attributes.body,
                reviewerNickname: resource.attributes.reviewerNickname,
                territory: resource.attributes.territory,
                createdDate: resource.attributes.createdDate,
                appVersion: nil,
                developerResponseState: responseID.map {
                    responseStates[$0] ?? DeveloperResponseState(apiValue: "UNKNOWN")
                }
            )
        }
        return ReviewPage(reviews: reviews, nextPage: next)
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        let url = path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appending(path: String(component))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AppError(kind: .other, message: "ReviewBar could not create an Apple API request.")
        }
        components.queryItems = query
        guard let result = components.url else {
            throw AppError(kind: .other, message: "ReviewBar could not encode an Apple API request.")
        }
        return result
    }

    private func fetchAllPages<Resource: Decodable & Sendable, Included: Decodable & Sendable>(
        from initialURL: URL
    ) async throws -> ([Resource], [Included]) {
        var nextURL: URL? = initialURL
        var resources: [Resource] = []
        var included: [Included] = []
        var visited: Set<URL> = []
        var pageCount = 0

        while let url = nextURL {
            try Task.checkCancellation()
            guard visited.insert(url).inserted, pageCount < 100 else {
                throw AppError(kind: .malformedResponse, message: "Apple returned a repeating or unexpectedly long pagination chain.")
            }
            let response = try await transport.get(url)
            let page = try AppleAPIDecoder.make().decode(JSONAPIPage<Resource, Included>.self, from: response.data)
            resources.append(contentsOf: page.data)
            included.append(contentsOf: page.included ?? [])
            nextURL = page.links.next
            pageCount += 1
        }
        return (resources, included)
    }

    private func capture<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Result<Value, Error> {
        do {
            return .success(try await operation())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .failure(error)
        }
    }
}

private struct FetchedBuilds: Sendable {
    let builds: [BuildInfo]
    let fallbackIcon: AppIconAsset?
}
