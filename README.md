# ReviewBar

ReviewBar is a focused, read-only App Store developer dashboard for iPhone. It connects directly to Apple’s official App Store Connect API, keeps the imported API key in the iOS Keychain, and has no ReviewBar account or backend.

The project targets iOS 26 with Swift 6 strict concurrency and SwiftUI.

## What is implemented

- Native five-tab interface for Apps, Overview, Releases, Reviews, and Builds.
- Individual and team App Store Connect API keys.
- Native `.p8` import with format and size validation.
- ES256 JWT generation with the correct individual (`sub: user`) and team (`iss`) claim sets, a ten-minute lifetime, GET-only scopes, raw 64-byte JOSE signatures, and in-memory reuse.
- App list search, sorting, activity filters, and at-a-glance release/build/review status.
- App Store version state plus separately labeled review-submission state and Apple-provided submission date.
- Device-local release transition observations and statistics without inventing Apple timestamps.
- Review reading, rating/territory/version filters where data exists, newest/oldest sorting, response status, local unread state, long-review detail, and pagination.
- The newest 200 iOS builds per app, including build number, marketing version, upload/expiration dates, processing status, TestFlight internal/external and beta-review states, audience, and selected App Store version when Apple exposes the relationship.
- Stale-while-refresh startup, protected on-disk cache, pull to refresh, partial section errors, and explicit empty/error states.
- Local demo data for multiple apps, release states, reviews, ready/processing/failed/expired builds, pagination, empty accounts, and API failures.
- Light and dark mode, Dynamic Type, VoiceOver semantics, landscape support, and native iOS 26 materials.
- A production app icon and privacy manifest.

ReviewBar intentionally contains no customer-review mutation endpoints. It cannot reply to, edit, or delete reviews.

## Architecture

```text
SwiftUI views + @MainActor AppModel
                 │
          DashboardRepository actor
          ┌──────┴────────┐
  App Store Connect    Protected local stores
  data provider        snapshot / unread / history
          │
  GET-only transport → JWT signer actor → CryptoKit
                              │
                         iOS Keychain
```

The API DTOs are separate from presentation-domain models. `DashboardRepository` coalesces the provider, caching, unread baseline, and release observation policy. Each app section can retain useful data if a different endpoint is unavailable or forbidden.

Key directories:

- `ReviewBar/API`: official Apple JSON:API DTOs and endpoint mapping.
- `ReviewBar/Services`: transport, JWT, Keychain, repository, caching, unread state, and release history.
- `ReviewBar/Domain`: UI-independent dashboard models and state mapping.
- `ReviewBar/UI`: feature-oriented SwiftUI screens.
- `ReviewBar/Fixtures`: deterministic local demo scenarios.
- `ReviewBarTests`: Swift Testing unit/integration coverage.
- `ReviewBarUITests`: XCTest UI coverage.
- `Documentation`: API decisions, limitations, and security threat model.

## Connect an App Store Connect key

1. The Account Holder first requests App Store Connect API access under **Users and Access → Integrations**, if the account has not already been approved.
2. For the recommended individual key, sign in as the intended user, open the username, choose **Edit Profile**, and create an Individual API Key. A dedicated Developer-role user limited to the intended apps is a strong default.
3. Alternatively, an Account Holder or Admin can create a team key under **Users and Access → Integrations**. Team keys apply account-wide and require the issuer ID.
4. Generate the key and download its `.p8` file. Apple permits that download only once.
5. In ReviewBar, choose the key type, enter the key ID (and issuer ID for a team key), import the `.p8`, then select **Test & Save**.
6. After a successful minimal API sync, ReviewBar stores the credential in the this-device-only Keychain and opens the Apps tab.

ReviewBar cannot delete or secure the original `.p8` file in Files. Keep that original protected and revoke the key in App Store Connect if it may have been exposed.

## Build and test

The generated Xcode project is committed, so `ReviewBar.xcodeproj` can be opened directly. [`project.yml`](project.yml) is the source of project structure and can be regenerated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodebuild \
  -project ReviewBar.xcodeproj \
  -scheme ReviewBar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build

xcodebuild \
  -project ReviewBar.xcodeproj \
  -scheme ReviewBar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  test
```

Run the app without credentials and choose **Explore with Local Sample Data** for the deterministic demo. Production mode never activates fixtures implicitly.

The automated suite covers JWT claims/signatures/lifetime/reuse, request scopes, real JSON:API pagination, repeated and hostile next links, 401 retry, malformed responses, cancellation, documented and future state mapping, partial-cache provenance, review filters and unread baselining, atomic local persistence, resubmission-safe release statistics, demo/live isolation, failed credential removal, primary navigation, specific error and empty states, dark mode, accessibility text size, and landscape layout.

## Security summary

- Private keys and identifiers are stored only in a dedicated, non-synchronizing `kSecClassGenericPassword` Keychain item using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- JWTs exist only in memory, expire after ten minutes, and are reused only while more than 60 seconds remain.
- The production transport creates only `GET` requests and scopes each token to its exact request path and query.
- Bearer-authenticated URLs and pagination links must use HTTPS, Apple’s exact API host, no user info, and no unexpected port. Cross-host redirects are rejected.
- Authenticated URL responses use an ephemeral session and are never placed in URL cache or cookies.
- Cached app/review data is deliberately decoded and written with complete-until-first-authentication file protection; credentials and raw responses never enter it.
- No analytics or third-party runtime dependencies are included. The code does not log PEM data, JWTs, authorization headers, raw responses, or review content.
- Disconnect removes the precise Keychain item, cached dashboards, unread state, and local release history.

See [`Documentation/Security.md`](Documentation/Security.md) for the threat model.

## Verified Apple API decisions and limitations

ReviewBar uses `https://api.appstoreconnect.apple.com/v1` and Apple’s current JSON:API resources:

- `GET /v1/apps?filter[appStoreVersions.platform]=IOS`
- `GET /v1/apps/{id}/appStoreVersions`
- `GET /v1/apps/{id}/reviewSubmissions`
- `GET /v1/apps/{id}/customerReviews`
- `GET /v1/builds?filter[app]={id}&filter[preReleaseVersion.platform]=IOS`

Important constraints verified from Apple’s current documentation:

- `reviewSubmissions` is used; the older `appStoreVersionSubmissions` API is deprecated.
- `appVersionState` is used; the older `appStoreState` field is deprecated.
- Apple exposes a review submission date, but not exact timestamps for entering Waiting for Review, entering In Review, approval, or every release transition. ReviewBar labels its own observations and never presents them as Apple facts.
- App-level review objects do not contain the reviewed app version. ReviewBar leaves that field absent unless version context is legitimately known.
- Apple has no server-side read/unread review state.
- Build processing has no percent or ETA. `VALID` means processing succeeded, not that a build is uniquely active in TestFlight. Apple provides no top-level build-platform filter, but does support `filter[preReleaseVersion.platform]=IOS`; ReviewBar uses that relationship filter and also verifies the mapped platform locally.
- To avoid repeatedly downloading an account’s entire build history, ReviewBar deliberately shows the newest 200 iOS builds for each app.
- A binary in Apple’s earliest upload/import stage may not yet have a Build resource. Version 1.0 begins showing it once it is represented by the Builds API; integrating the separate `buildUploads` resource is a recommended follow-up.
- Multiple TestFlight builds can be active; ReviewBar does not invent a single “active build.”
- Apple webhooks require a reachable developer server. Without a backend, iOS background refresh is opportunistic and cannot guarantee timely alerts.

Because reliable background notifications would require a weaker Keychain availability class and still could not promise timely polling, version 1.0 deliberately keeps refresh foreground-driven. A widget is also omitted so no extension or app group receives credential access. These are conscious security/reliability decisions, not hidden unavailable features.

See [`Documentation/AppStoreConnectAPI.md`](Documentation/AppStoreConnectAPI.md) for official source links and field-level notes.

## Manual steps before App Store submission

- Replace `com.reviewbar.ReviewBar` with a bundle identifier you own and select your Apple Developer signing team.
- Test with real individual and team API keys across the roles/accounts you intend to support; no working credential is included in this repository.
- Supply App Store listing text, screenshots, support/privacy-policy URLs, age rating, and final legal metadata.
- Confirm the encryption/export-compliance answer for your organization. The project declares no non-exempt encryption because CryptoKit is used only for standard API authentication.
- Archive with your distribution identity and run Xcode’s validation before upload.

## Recommended next improvements

1. A credential-free widget that reads only a minimal, redacted app-group snapshot.
2. Opt-in opportunistic background refresh with precise expectation-setting and contextual notification permission.
3. More locally observed release history and statistics after real-world use.
4. TestFlight group/tester detail where it stays focused and permissions permit it.
