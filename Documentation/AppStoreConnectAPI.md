# App Store Connect API decisions

ReviewBar 0.1.1 was checked against Apple’s official App Store Connect API documentation current on 2026-08-01. Core data is never scraped from App Store Connect or the public App Store.

## Authentication

- [App Store Connect API setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
- [Generating tokens](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)

Team JWTs use `iss`; individual JWTs use literal `sub: user` and omit `iss`. Both use ES256, `kid`, `iat`, `exp`, `aud: appstoreconnect-v1`, and an exact request scope. Apple caps most tokens at 20 minutes; ReviewBar uses ten minutes.

## Apps, platforms, and icons

- [`GET /v1/apps`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps)
- [`Platform`](https://developer.apple.com/documentation/appstoreconnectapi/platform)
- [`App.appStoreIcon`](https://developer.apple.com/documentation/appstoreconnectapi/app/relationships-data.dictionary/appstoreicon-data.dictionary)
- [Build icons](https://developer.apple.com/documentation/appstoreconnectapi/build-icons)

The apps request has **no platform filter**. It requests `appStoreIcon`, includes the related `buildIcons` resource, follows all safe `links.next` pages, and deduplicates both apps and repeated included resources.

Current platform values handled exactly are `IOS`, `MAC_OS`, `TV_OS`, and `VISION_OS`; unknown future values are retained as Other. iPadOS is represented by `IOS`. Apple models watch content through its parent app/build and icon bundle types rather than a separate `WATCH_OS` Platform value.

Icon priority is:

1. the app’s related official App Store icon;
2. an `APP_STORE` icon from the newest suitable build;
3. a deterministic generated local fallback.

Apple `ImageAsset.templateUrl` placeholders `{w}`, `{h}`, and `{f}` may arrive percent encoded. ReviewBar resolves either form, requires HTTPS without user information, downloads from a separate unauthenticated session, verifies that ImageIO can decode the bytes, and caches them with a bounded disk policy.

## App Store versions and submissions

- [`GET /v1/apps/{id}/appStoreVersions`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-appstoreversions)
- [`GET /v1/apps/{id}/reviewSubmissions`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-reviewsubmissions)
- [`AppVersionState`](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate)

No platform filter is applied. The current `appVersionState` is preserved, including unknown future raw values. Review-submission state remains separate from version state. `submittedDate` is authoritative for submission; `createdDate` is resource creation and `earliestReleaseDate` is scheduling, so neither is relabeled as a transition.

## Customer reviews

- [`GET /v1/apps/{id}/customerReviews`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-customerreviews)
- [`CustomerReview`](https://developer.apple.com/documentation/appstoreconnectapi/customerreview/attributes-data.dictionary)

ReviewBar requests rating, title, body, reviewer nickname, creation date, territory, and included developer response. App-level customer reviews do not expose the reviewed app version, so the UI leaves that absent unless legitimate version context exists. ReviewBar has no review POST/PATCH/DELETE path and maintains unread state only on device.

## Builds and TestFlight

- [`GET /v1/builds`](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds)
- [`Build`](https://developer.apple.com/documentation/appstoreconnectapi/build/attributes-data.dictionary)
- [`InternalBetaState`](https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate)
- [`ExternalBetaState`](https://developer.apple.com/documentation/appstoreconnectapi/externalbetastate)

Builds are filtered only by `filter[app]={id}`, not by iOS. The related pre-release version supplies marketing version and platform. Included beta detail, beta review submission, App Store version, and icons provide TestFlight/release context. ReviewBar requests 200 per page and follows Apple’s complete safe pagination chain so an iOS-heavy first page cannot hide later macOS, tvOS, visionOS, or still-relevant TestFlight builds.

`processingState` is preserved exactly. `VALID` means Apple finished processing, not that the build is the only active TestFlight build. Expiration uses Apple’s `expired` and `expirationDate` fields. The separate `buildUploads` resource may represent a binary before its Build resource exists; ReviewBar currently begins showing it once it reaches Builds.

## Analytics Reports

- [Analytics Reports overview](https://developer.apple.com/documentation/analytics-reports)
- [`analyticsReportRequests`](https://developer.apple.com/documentation/appstoreconnectapi/analyticsreportrequest)
- [`analyticsReports`](https://developer.apple.com/documentation/appstoreconnectapi/analyticsreport)
- [`analyticsReportInstances`](https://developer.apple.com/documentation/appstoreconnectapi/analyticsreportinstance)
- [`analyticsReportSegments`](https://developer.apple.com/documentation/appstoreconnectapi/analyticsreportsegment)

ReviewBar uses this official chain:

```text
GET  /v1/apps/{id}/analyticsReportRequests
POST /v1/analyticsReportRequests                 (ONGOING, user initiated)
GET  /v1/analyticsReportRequests/{id}/reports
GET  /v1/analyticsReports/{id}/instances?filter[granularity]=DAILY
GET  /v1/analyticsReportInstances/{id}/segments
GET  /v1/analyticsReportSegments/{id}            (segment metadata when needed)
GET  signed segment URL                           (gzip TSV; no Apple bearer)
```

Existing active ONGOING requests are preferred, with an active ONE_TIME_SNAPSHOT as fallback. Creating the first ongoing request can require Admin permission; ReviewBar surfaces that role requirement rather than a generic error. Stopped requests and still-generating reports remain distinct states.

Segment URLs are short-lived downloads. ReviewBar validates HTTPS, uses an unauthenticated session, limits compressed/decompressed sizes, decompresses gzip, parses quoted tab-separated rows, validates each segment’s required schema, ignores unknown added columns, and aggregates reports incrementally. `processingDate` corrections replace the same report instance rather than double-counting it. Imported instance aggregates are cached because daily instances are retained for a limited period.

Analytics update frequency and fields vary by report. The UI renders only metrics actually present and distinguishes exact zero, no rows, unavailable metric, and privacy-insufficient data. It does not infer unique counts, conversion, proceeds, or paying users from incompatible fields. Sales and Trends is a separate reporting system and is not used in 0.1.1.

## Webhooks

- [App Store Connect webhooks](https://developer.apple.com/documentation/appstoreconnectapi/webhooks)
- [Webhook events](https://developer.apple.com/documentation/appstoreconnectapi/webhook-events)

On-device configuration uses:

```text
POST   /v1/webhooks
GET    /v1/apps/{id}/webhooks
DELETE /v1/webhooks/{id}
POST   /v1/webhookPings
```

The phone creates each webhook using its locally held App Store Connect credential. Supported notification choices are `APP_STORE_VERSION_APP_VERSION_STATE_UPDATED`, `BUILD_UPLOAD_STATE_UPDATED`, and `BUILD_BETA_DETAIL_EXTERNAL_BUILD_STATE_UPDATED`. The relay also understands Apple’s beta crash/screenshot feedback event types, but 0.1.1 keeps the product controls focused on release/build status.

Apple signs the exact request body with HMAC-SHA256 in `x-apple-signature: hmacsha256=<hex>`. Redelivery uses the same event ID. App-version and external-build state events can contain an authoritative `attributes.timestamp`; build-upload events do not document one. No timestamp is synthesized. Apple documents no customer App Store review-created event.

The callback URL is installation/channel-specific and is persisted before Apple creation. If a create response is lost or local persistence fails, ReviewBar lists the app's webhooks and matches that exact URL before cleanup, preventing an ambiguous Apple-side webhook from becoming orphaned. The relay’s normalized feed is oldest-first and uses an opaque tuple cursor rather than a timestamp-only watermark. ReviewBar records an app-version transition by its webhook instance ID and monitored app mapping even if the corresponding REST version has not appeared yet; the later REST refresh then supplies the display version without losing the authoritative transition time.

Webhook management is limited to Account Holder, Admin, and App Manager, and Apple limits configurations per app. The UI reports role failures explicitly.

## Pagination and errors

- [Paging information](https://developer.apple.com/documentation/appstoreconnectapi/paginginformation/paging-data.dictionary)
- [Handling errors](https://developer.apple.com/documentation/appstoreconnectapi/interpreting-and-handling-errors)
- [Rate limits](https://developer.apple.com/documentation/appstoreconnectapi/identifying-rate-limits)

ReviewBar follows `links.next`, validates the exact Apple HTTPS host, rejects repeated/overlong chains, and deduplicates resource IDs. It retries one 401 with a fresh token and separately maps authentication, permission, rate-limit, service, network, and malformed-response failures. Apple publishes no single fixed account quota, so none is hardcoded.

## Remaining external limitations

Apple does not expose a review queue estimate, build-processing percentage/ETA, Apple-side unread review flag, one uniquely active TestFlight build, a customer-review webhook, or exact timestamps for every REST-visible state. ReviewBar does not fabricate them. Release history orders timestamp authority as Apple webhook, Apple API field, then labeled local observation.
