# App Store Connect API decisions

ReviewBar was implemented against Apple’s official App Store Connect API documentation and release notes current on 2026-07-31 (API 4.4.1).

## Authentication

- [App Store Connect API setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
- [Generating tokens for API requests](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Revoking API keys](https://developer.apple.com/documentation/appstoreconnectapi/revoking-api-keys)

Team JWTs use `iss`; individual JWTs use the literal `sub: user` and omit `iss`. Both use an ES256 header containing `kid`, `iat`, `exp`, `aud: appstoreconnect-v1`, and optional request scope. Apple caps most lifetimes at 20 minutes; ReviewBar uses 10 minutes.

## Resources

### Apps

[`GET /v1/apps`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps) pages with a limit of 200 and uses the `name`, `bundleId`, `sku`, and `primaryLocale` fields.

### App Store versions and submissions

- [`GET /v1/apps/{id}/appStoreVersions`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-appstoreversions)
- [`AppVersionState`](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate)
- [`GET /v1/apps/{id}/reviewSubmissions`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-reviewsubmissions)
- [App and submission statuses](https://developer.apple.com/help/app-store-connect/reference/app-information/app-and-submission-statuses)

ReviewBar maps the current `appVersionState`, preserves unknown future raw values, and keeps the review submission state separate. The submission’s `submittedDate` is an Apple timestamp. `createdDate` is only record creation, and `earliestReleaseDate` is scheduling—not actual release—so neither is relabeled.

### Customer reviews

- [`GET /v1/apps/{id}/customerReviews`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-customerreviews)
- [`CustomerReview` attributes](https://developer.apple.com/documentation/appstoreconnectapi/customerreview/attributes-data.dictionary)
- [`CustomerReviewResponseV1` attributes](https://developer.apple.com/documentation/appstoreconnectapi/customerreviewresponsev1/attributes-data.dictionary)

The app requests rating, title, body, nickname, creation date, territory, and an included response. App-level review resources have no app-version attribute. ReviewBar’s networking module contains no POST, PATCH, or DELETE review operations.

### Builds and TestFlight

- [`GET /v1/builds`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds)
- [`Build` attributes](https://developer.apple.com/documentation/appstoreconnectapi/build/attributes-data.dictionary)
- [`InternalBetaState`](https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate)
- [`ExternalBetaState`](https://developer.apple.com/documentation/appstoreconnectapi/externalbetastate)
- [`BetaReviewState`](https://developer.apple.com/documentation/appstoreconnectapi/betareviewstate)

Build `version` is the build number. The related pre-release version supplies the marketing version and platform. `processingState` is preserved exactly; expiration uses Apple’s `expired` and `expirationDate`. TestFlight state and the App Store version relationship are labeled separately.

## Pagination and errors

- [Paging information](https://developer.apple.com/documentation/appstoreconnectapi/paginginformation/paging-data.dictionary)
- [Interpreting and handling errors](https://developer.apple.com/documentation/appstoreconnectapi/interpreting-and-handling-errors)
- [Identifying rate limits](https://developer.apple.com/documentation/appstoreconnectapi/identifying-rate-limits)

ReviewBar follows `links.next` rather than constructing cursors, validates every next URL, stops repeated/overlong chains, and deduplicates resource IDs. It retries one 401 with a fresh token, then maps authentication, permission, rate-limit, service, network, and malformed-response failures separately. Apple does not document one fixed rate quota or guarantee `Retry-After`, so none is hardcoded.

## Unsupported exactness

Apple’s ordinary read API does not expose exact timestamps for every release transition, a review queue estimate, build processing progress, an Apple-side unread flag, or one uniquely active TestFlight build. Apple webhooks can provide state-change events but require an HTTPS server; see [webhook events](https://developer.apple.com/documentation/appstoreconnectapi/webhook-events). ReviewBar has no backend, so these capabilities are not fabricated.

