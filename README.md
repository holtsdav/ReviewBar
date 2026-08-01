# ReviewBar

ReviewBar is a focused native iPhone dashboard for independent App Store developers. The iPhone talks directly to Apple’s official App Store Connect API; the imported `.p8` key stays in the iOS Keychain. An optional, isolated notification relay can receive Apple-signed webhooks and send APNs alerts, but it never receives App Store Connect credentials.

The project targets iOS 26, Swift 6 strict concurrency, SwiftUI, and version **0.1.1**.

## Product surface

- **Apps:** every app visible to the key, without a global iOS filter. iOS/iPadOS, macOS, tvOS, and visionOS releases and builds are preserved. Multi-platform apps show each platform separately.
- **App icons:** official `appStoreIcon` first, the newest suitable build’s `APP_STORE` icon second, and a deterministic local fallback otherwise. Downloaded icons use a bounded protected disk cache and remain available offline.
- **Overview:** a compact operational dashboard for current release, latest build, newest review, and cached seven-day Analytics. Release History and Builds are destinations from Overview rather than permanent tabs.
- **Reviews:** read-only customer-review reading, filters, sorting, response state, pagination, and device-local unread state.
- **Analytics:** official Analytics Reports discovery, initial ongoing-request creation, report/instance/segment pagination, gzip TSV import, schema validation, correction handling, aggregation, caching, data-through dates, and 7D/30D/90D/1Y ranges.
- **Settings:** compact grouped account, data, optional notification, privacy, and about controls.
- **Real-time updates:** optional per-app release, build-upload, and external-TestFlight alerts through official App Store Connect webhooks and the small Cloudflare relay in `NotificationRelay/`.
- **Resilience:** stale-while-refresh launch, section-level cached fallback, explicit permission/offline/rate-limit/malformed/error states, and deterministic test-fixture scenarios kept out of the signed-in product flow.
- **Accessibility:** light/dark mode, Dynamic Type reflow, VoiceOver semantics, native hit targets, and portrait/landscape layouts.

ReviewBar has no customer-review mutation operations and never replies to, edits, or deletes reviews.

## Navigation

The global tab bar contains **Apps**, **Reviews**, and **Analytics**. Selecting an app opens its operational Overview; focused Release History and Builds screens are destinations from Overview rather than permanent tabs.

```text
Apps ── select app ──> Overview ──> Release History
                         │          └─> Builds
                         ├────────────> Reviews
                         └────────────> Analytics
```

## Architecture

```text
SwiftUI + @MainActor AppModel
        │
        ├─ DashboardRepository actor ── Apple REST resources
        ├─ AnalyticsRepository actor ── Analytics Reports + signed gzip TSV
        ├─ protected local caches / unread state / release history / icons
        └─ Keychain ── short-lived ES256 JWT signer

Optional real-time path:
Apple webhook ── HMAC ──> Cloudflare Worker + D1 + Queue ──> APNs ──> iPhone
                                  ▲
          opaque installation/channel metadata only; no user's Apple key/JWT
```

Provider DTOs are separate from presentation-domain models. Repository actors coalesce requests, validate pagination, merge safe cached data after partial failures, and prevent canceled sessions from repopulating cleared caches.

Key directories:

- `ReviewBar/API`: Apple JSON:API and Analytics DTO/endpoint mapping.
- `ReviewBar/Services`: networking, JWT, Keychain, repositories, persistence, TSV/gzip, icon cache, and optional relay client.
- `ReviewBar/Domain`: UI-independent release, build, review, Analytics, platform, and real-time models.
- `ReviewBar/UI`: feature-oriented SwiftUI screens.
- `ReviewBar/Fixtures`: deterministic multi-platform previews and test scenarios that never ship as a signed-in product mode.
- `NotificationRelay`: isolated Cloudflare Worker, D1 migration, queue/APNs adapter, and runtime tests.
- `ReviewBarTests` / `ReviewBarUITests`: unit, integration, and primary-flow coverage.
- `Documentation`: verified API decisions and security threat model.

## Connect an App Store Connect key

1. If necessary, the Account Holder requests App Store Connect API access under **Users and Access → Integrations**.
2. For an individual key, create the key from the intended App Store Connect user’s profile. A dedicated app-limited user is the least-privilege default.
3. Alternatively, an Account Holder or Admin can create a team key under **Users and Access → Integrations**; team keys also require the issuer ID.
4. Download the `.p8` once, record its key ID, and keep the original file secure.
5. In ReviewBar choose the key type, enter the identifiers, import the `.p8`, and select **Test & Save**.
6. ReviewBar verifies a minimal request before saving the credential with this-device-only Keychain protection.

Analytics reading depends on the API key’s role and app access. Creating the first ongoing Analytics Report request requires an Admin-capable key; Admin, Sales and Reports, or Finance keys can read existing reports. Creating App Store Connect webhooks requires Account Holder, Admin, or App Manager.

## Build and test

The generated `ReviewBar.xcodeproj` is committed. [`project.yml`](project.yml) is its XcodeGen source.

```sh
xcodegen generate
xcodebuild -project ReviewBar.xcodeproj -scheme ReviewBar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild -project ReviewBar.xcodeproj -scheme ReviewBar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Run the simulator tests to exercise the signed-out, empty-account, unavailable-service, and multi-platform fixture scenarios. Fixtures are injected only by `#if DEBUG` UI-test launch arguments; production builds never activate them implicitly.

Relay validation is independent:

```sh
cd NotificationRelay
npm install
npm run check
npm test
```

## API and data limitations

- Analytics Reports are delayed, app/report dependent, can take 1–2 days to appear initially, and are not real-time. The UI shows the actual data-through date for each metric and distinguishes zero, no data, unavailable, and insufficient data.
- Apple documents the Analytics Report request and download endpoints, but some production accounts have received an undocumented `METHOD_NOT_ALLOWED` response when creating a request. ReviewBar keeps the cache intact and explains the required role/availability check instead of retrying the mutation indefinitely.
- Apple may add Analytics TSV columns; ReviewBar ignores unknown additions but rejects missing or malformed required date/value fields. It does not fabricate unsupported metrics.
- Analytics imports are sequential and enforce a 16 MiB per-segment compressed/inflated safety bound to keep memory predictable on small iPhones; an oversized report is labeled unavailable while other report types remain usable.
- Apple exposes no customer App Store review-created webhook. Review detection remains refresh-based.
- `BUILD_UPLOAD_STATE_UPDATED` does not document a transition timestamp or build number. ReviewBar does not invent either.
- Apple’s normal REST resources do not provide every exact release transition time. Release history prefers Apple webhook timestamps, then Apple API timestamps, then clearly labeled local observations.
- Apps can contain multiple active TestFlight builds; ReviewBar does not invent one globally “active” build.
- iPadOS uses Apple’s `IOS` platform value. Apple models watch apps inside a parent app/build relationship; there is no separate `WATCH_OS` Platform value to filter.

See [`Documentation/AppStoreConnectAPI.md`](Documentation/AppStoreConnectAPI.md) for endpoint and schema notes.

## Security summary

- User App Store Connect private keys and identifiers remain in a non-synchronizing `WhenUnlockedThisDeviceOnly` Keychain item.
- Short-lived ES256 JWTs exist only in memory; read-only GET tokens use Apple's request-path scope, while mutation tokens intentionally omit the GET-only scope claim.
- Apple API sessions are ephemeral, reject unsafe hosts/redirects, and do not cache credentials or raw responses.
- Dashboard, Analytics, release-history, and icon caches contain no authentication secret and use iOS file protection.
- The optional relay stores only opaque installation/channel metadata, a hash of its installation bearer, encrypted APNs/webhook secrets, normalized recent events, and notification preferences.
- Relay HMAC validation covers the exact raw body before JSON parsing; event IDs are deduplicated before APNs dispatch.
- Source, fixtures, logs, analytics, and UserDefaults contain no private key, JWT, relay bearer, APNs token, or webhook secret.

See [`Documentation/Security.md`](Documentation/Security.md) and [`NotificationRelay/README.md`](NotificationRelay/README.md).

## Manual release steps

- Use a bundle identifier and Apple Developer team you control.
- Test live data using real individual/team keys and representative roles/accounts; no credential is included.
- For push notifications, deploy the relay, supply its HTTPS base URL through `REVIEWBAR_RELAY_BASE_URL`, configure APNs secrets, enable the production push capability, and apply the D1 migration. The core app does not require this.
- Supply listing text, screenshots, support/privacy-policy URLs, age rating, and final legal metadata.
- Reconfirm the export-compliance declaration for your organization, archive with the distribution identity, and run Xcode validation.

## Recommended next improvements

1. Add App Attest enrollment to the public relay before broad distribution.
2. Add a credential-free widget backed by a minimal redacted app-group snapshot.
3. Expand long-term release statistics as authoritative webhook history accumulates.
4. Add focused TestFlight group/tester detail where the official API and permissions allow it.
