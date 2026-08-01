# Security model

## Assets and trust boundaries

The user’s App Store Connect `.p8` is the highest-value asset. If stolen, it can be used outside ReviewBar with that key’s roles and app access. ReviewBar reduces exposure but cannot make a compromised or jailbroken device trustworthy.

Trust boundaries:

1. Files picker → ReviewBar memory during import.
2. ReviewBar → iOS Keychain for App Store Connect and optional relay credentials.
3. ReviewBar → `api.appstoreconnect.apple.com` through system TLS.
4. Apple Analytics signed URLs → isolated unauthenticated downloader.
5. Decoded Apple models → protected local caches.
6. Optional: iPhone → ReviewBar relay enrollment/configuration.
7. Optional: Apple → relay webhook endpoint → Queue → APNs → iPhone.

The optional relay is not trusted with App Store Connect credentials. It never receives a user `.p8`, key/issuer ID, Apple JWT, or Apple authorization header.

## On-device controls

- Imports accept one regular file of at most 16 KiB, validate one PKCS#8 PEM block, and parse it as P-256 before use.
- The security-scoped source file is accessed only during import and is not bookmarked or copied.
- App Store Connect credentials use a precise non-synchronizing generic-password Keychain item with `WhenUnlockedThisDeviceOnly` accessibility.
- The opaque relay installation bearer, active channel mapping, and any provisional cleanup identifiers use a separate this-device-only Keychain item; neither enters UserDefaults or dashboard caches. Provisional records include the deterministic callback URL, are written before Apple creation/confirmation, and remain until both Apple and relay cleanup succeed. An ambiguous create is reconciled by listing that app's Apple webhooks and matching the exact callback URL before disconnect can erase the credential.
- ES256 JWTs live only in signer-actor memory, last ten minutes, and rotate with 60 seconds remaining.
- Tokens are scoped to the exact method/path. Authorization is never placed in a URL.
- Authenticated URLs and redirects must remain on Apple’s exact HTTPS host. Sessions disable cookies and URL caching.
- Analytics segment and icon downloads use separate unauthenticated sessions, validate HTTPS/no user info, impose size limits, and validate decoded content before caching.
- Dashboard, Analytics, icon, unread, and release-history files contain no authentication secrets and use atomic iOS file protection.
- Source code does not log credentials, JWTs, relay bearers, device tokens, webhook secrets, authorization headers, raw Apple responses, or customer-review bodies.
- Disconnect cancels and awaits serialized real-time work, then attempts Apple and relay cleanup before deleting the user credential. If relay cleanup fails, the connection and its separate Keychain bearer are deliberately retained so deletion can be retried. If only Apple cleanup fails, relay delivery is stopped and the UI tells the user to remove any stale Apple webhook manually.
- An authoritative Apple 4xx rejection (including role denial) is classified as a non-creation and clears only the provisional relay channel. Transport loss, 5xx responses, and malformed success responses remain ambiguous and trigger exact callback-URL reconciliation.

## Relay controls

- D1 stores an opaque installation ID, a SHA-256 hash of its random bearer, AES-GCM-encrypted APNs device token, channel/app metadata, encrypted high-entropy webhook secret, event preferences, Apple webhook ID, and normalized recent event rows for idempotency/history.
- The bearer token itself is returned once to the device and not stored in plaintext server-side.
- Apple HMAC-SHA256 is verified over the exact raw body with constant-time comparison before JSON parsing or queueing.
- Unknown/malformed data is rejected; signed ping/future envelope types are accepted without inventing semantics.
- D1’s channel-scoped event primary key deduplicates Apple redelivery. An atomic pending/claimed/enqueued outbox state prevents concurrent redeliveries from enqueueing twice; queue-consumer failures return the durable row to pending so cron can recover even after DLQ exhaustion.
- Raw webhook payloads, Apple credentials, signed Analytics URLs, and full Apple responses are not stored or logged.
- APNs uses ReviewBar’s dedicated server key and short-lived ES256 provider JWT. A `410`/permanent token response disables that installation; token rotation can re-enable it. Retryable failures use Cloudflare Queue retry, a dead-letter queue, and the D1 outbox/cron recovery path.
- Channel and installation deletion are bearer authenticated. Deleting an installation cascades its channel/event mappings.
- Secrets are Wrangler-managed and absent from source control. The public ingress must use HTTPS.

## Abuse and residual risks

- The minimal enrollment endpoint is intentionally accountless and accepts structurally valid APNs device tokens. Before public launch, apply Cloudflare WAF rate limits to enrollment and event endpoints. App Attest is the recommended next hardening layer against automated enrollment abuse.
- A relay operator with both database access and the relay encryption secret could decrypt APNs/webhook secrets. Keep Wrangler/admin access least privilege, use a dedicated environment, and plan a re-encryption migration before rotating the at-rest key.
- Apple documents HMAC and event-ID redelivery but no independent timestamp/nonce replay rule for webhook envelopes. ReviewBar therefore relies on authenticated body integrity and event-ID idempotency rather than inventing a replay window.
- Swift and CryptoKit do not guarantee deterministic zeroization of temporary secret buffers. The import UI minimizes copies and clears retained PEM after connection.
- A malicious trusted root, compromised OS, hostile keyboard, injected runtime, or stolen unlocked device can defeat on-device controls.
- Cached reviews and analytics are sensitive developer data even though they are not authentication secrets. They become available after first device unlock.
- A team key can be account-wide. An individual key belonging to a dedicated app-limited user is the least-exposure default.

## Operational response

- If a user key may be exposed, revoke it in App Store Connect immediately, remove the ReviewBar connection, create a replacement, and review the user’s role/app access.
- If a relay secret may be exposed, disable/deploy a clean relay environment, delete affected Apple webhooks, rotate APNs credentials and relay secrets, then re-enroll devices. Do not rotate the AES-GCM at-rest key without migrating encrypted records.
- Treat unexpected APNs volume, signature failures, queue growth, or repeated registration bursts as security signals; monitor aggregate counts without logging payloads or device tokens.
